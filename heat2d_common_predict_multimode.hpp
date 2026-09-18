#pragma once

#include <mpi.h>
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace heat2d {

constexpr int TAG_X_TO_LEFT   = 100;
constexpr int TAG_X_TO_RIGHT  = 101;
constexpr int TAG_Y_TO_UP     = 200;
constexpr int TAG_Y_TO_DOWN   = 201;
constexpr int TAG_SUP_TO_UP   = 300;
constexpr int TAG_SUP_TO_DOWN = 301;
constexpr int RING = 8;

struct Config {
    int nx_global = 24576;   // pontos interiores em x
    int ny_global = 4096;    // pontos interiores em y
    int steps = 100;
    double alpha = 0.1;
    double cfl = 0.90;       // fração do limite FTCS 2D
    std::string policy = "always"; // always | cost | wait (controle SUPPORT+WAIT)
    double beta = 1.0;       // cost: recompute se E[wait] > beta*E[recompute]
    int inject_delay_us = 0;
    int inject_every = 0;
    int inject_node = -1;    // -1 = desabilitado; >=0 = índice lógico do nó
    int inject_local_rank = -1; // -1 = todos os ranks do nó escolhido
    bool validate_late = true;
    bool verbose = false;
};

struct Block {
    int n = 0;
    int start = 0;
};

inline Block split_block(int N, int P, int coord) {
    const int q = N / P;
    const int r = N % P;
    Block b;
    b.n = q + (coord < r ? 1 : 0);
    b.start = coord * q + std::min(coord, r);
    return b;
}

struct Topology {
    int world_rank = 0, world_size = 1;
    MPI_Comm local_comm = MPI_COMM_NULL;
    int local_rank = 0, local_size = 1;
    int leader_world = 0;
    int node_index = 0, num_nodes = 1;
    int px = 0, py = 0;
    int left = MPI_PROC_NULL, right = MPI_PROC_NULL;
    int up = MPI_PROC_NULL, down = MPI_PROC_NULL;
    std::vector<int> world_to_node;
    std::vector<int> world_to_local;
    std::vector<int> coord_to_world;

    int at(int node, int lr) const {
        return coord_to_world[node * local_size + lr];
    }
};

inline Topology build_topology(MPI_Comm world) {
    Topology t;
    MPI_Comm_rank(world, &t.world_rank);
    MPI_Comm_size(world, &t.world_size);

    MPI_Comm_split_type(world, MPI_COMM_TYPE_SHARED, t.world_rank, MPI_INFO_NULL, &t.local_comm);
    MPI_Comm_rank(t.local_comm, &t.local_rank);
    MPI_Comm_size(t.local_comm, &t.local_size);

    int leader = (t.local_rank == 0) ? t.world_rank : -1;
    MPI_Bcast(&leader, 1, MPI_INT, 0, t.local_comm);
    t.leader_world = leader;

    std::vector<int> leaders(t.world_size), localranks(t.world_size), localsizes(t.world_size);
    MPI_Allgather(&t.leader_world, 1, MPI_INT, leaders.data(), 1, MPI_INT, world);
    MPI_Allgather(&t.local_rank, 1, MPI_INT, localranks.data(), 1, MPI_INT, world);
    MPI_Allgather(&t.local_size, 1, MPI_INT, localsizes.data(), 1, MPI_INT, world);

    const int expected_local = localsizes.front();
    for (int s : localsizes) {
        if (s != expected_local) {
            if (t.world_rank == 0)
                std::cerr << "ERRO: número de ranks por nó não uniforme.\n";
            MPI_Abort(world, 2);
        }
    }

    std::vector<int> unique = leaders;
    std::sort(unique.begin(), unique.end());
    unique.erase(std::unique(unique.begin(), unique.end()), unique.end());
    t.num_nodes = static_cast<int>(unique.size());
    auto it = std::lower_bound(unique.begin(), unique.end(), t.leader_world);
    t.node_index = static_cast<int>(it - unique.begin());

    t.world_to_node.resize(t.world_size);
    t.world_to_local = localranks;
    t.coord_to_world.assign(t.num_nodes * t.local_size, -1);
    for (int r = 0; r < t.world_size; ++r) {
        int ni = static_cast<int>(std::lower_bound(unique.begin(), unique.end(), leaders[r]) - unique.begin());
        t.world_to_node[r] = ni;
        const int lr = localranks[r];
        if (lr < 0 || lr >= t.local_size) MPI_Abort(world, 3);
        t.coord_to_world[ni * t.local_size + lr] = r;
    }
    for (int v : t.coord_to_world) {
        if (v < 0) {
            if (t.world_rank == 0) std::cerr << "ERRO: mapeamento lógico incompleto.\n";
            MPI_Abort(world, 4);
        }
    }

    // Malha lógica Py x Px = numero_de_nos x ranks_por_no.
    // x varia apenas dentro do nó; y varia apenas entre nós.
    t.px = t.local_rank;
    t.py = t.node_index;
    t.left  = (t.px > 0) ? t.at(t.py, t.px - 1) : MPI_PROC_NULL;
    t.right = (t.px + 1 < t.local_size) ? t.at(t.py, t.px + 1) : MPI_PROC_NULL;
    t.up    = (t.py > 0) ? t.at(t.py - 1, t.px) : MPI_PROC_NULL;
    t.down  = (t.py + 1 < t.num_nodes) ? t.at(t.py + 1, t.px) : MPI_PROC_NULL;

    return t;
}

inline Config parse_args(int argc, char** argv) {
    Config c;
    auto need = [&](int& i) -> std::string {
        if (i + 1 >= argc) throw std::runtime_error(std::string("faltou valor para ") + argv[i]);
        return argv[++i];
    };
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--nx") c.nx_global = std::stoi(need(i));
        else if (a == "--ny") c.ny_global = std::stoi(need(i));
        else if (a == "--steps") c.steps = std::stoi(need(i));
        else if (a == "--alpha") c.alpha = std::stod(need(i));
        else if (a == "--cfl") c.cfl = std::stod(need(i));
        else if (a == "--policy") c.policy = need(i);
        else if (a == "--beta") c.beta = std::stod(need(i));
        else if (a == "--inject-delay-us") c.inject_delay_us = std::stoi(need(i));
        else if (a == "--inject-every") c.inject_every = std::stoi(need(i));
        else if (a == "--inject-node") c.inject_node = std::stoi(need(i));
        else if (a == "--inject-local-rank") c.inject_local_rank = std::stoi(need(i));
        else if (a == "--validate-late") c.validate_late = (std::stoi(need(i)) != 0);
        else if (a == "--verbose") c.verbose = (std::stoi(need(i)) != 0);
        else if (a == "--help") {
            if (true) {
                std::cout << "Opções: --nx N --ny N --steps N --alpha A --cfl F\n"
                          << "         --policy always|cost|wait --beta B\n"
                          << "         --inject-delay-us U --inject-every K --inject-node I\n"
                          << "         --inject-local-rank R --validate-late 0|1 --verbose 0|1\n";
            }
            std::exit(0);
        } else {
            throw std::runtime_error("opção desconhecida: " + a);
        }
    }
    if (c.nx_global <= 0 || c.ny_global <= 0 || c.steps <= 0 || c.alpha <= 0.0)
        throw std::runtime_error("parâmetros numéricos inválidos");
    if (!(c.cfl > 0.0 && c.cfl <= 1.0))
        throw std::runtime_error("--cfl deve estar em (0,1]");
    if (c.policy != "always" && c.policy != "cost" && c.policy != "wait")
        throw std::runtime_error("--policy deve ser always, cost ou wait");
    return c;
}

class Grid {
public:
    int ny = 0, nx = 0, pitch = 0;
    std::vector<double> a;
    Grid() = default;
    Grid(int ny_, int nx_) : ny(ny_), nx(nx_), pitch(nx_ + 2), a(static_cast<size_t>(ny_ + 2) * (nx_ + 2), 0.0) {}
    inline double& operator()(int i, int j) { return a[static_cast<size_t>(i) * pitch + j]; }
    inline const double& operator()(int i, int j) const { return a[static_cast<size_t>(i) * pitch + j]; }
};

inline void spin_delay_us(int us) {
    if (us <= 0) return;
    const double t0 = MPI_Wtime();
    const double target = us * 1e-6;
    volatile double x = 1.0000001;
    while (MPI_Wtime() - t0 < target) {
        x = x * 1.0000000001 + 1e-12;
    }
    (void)x;
}

struct Ewma {
    double value = 0.0;
    bool initialized = false;
    void add(double x, double w = 0.2) {
        if (!initialized) { value = x; initialized = true; }
        else value = (1.0 - w) * value + w * x;
    }
};

struct Stats {
    long long reads = 0;
    long long waits = 0;
    long long recomputes = 0;
    long long support_unavailable = 0;
    long long cleanup_waits = 0;
    double wait_s = 0.0;
    double recompute_s = 0.0;
    double cleanup_wait_s = 0.0;
    double late_validation_max = 0.0;

    // Diagnostico do PREDICT: a previsao nunca substitui o halo real.
    long long predict_tests = 0;
    double predict_linf_sum = 0.0;
    double predict_linf_max = 0.0;
};

struct RemoteSlot {
    int step = -1;
    std::vector<double> halo_recv_up, halo_recv_down;
    std::vector<double> halo_send_up, halo_send_down;
    std::vector<double> sup_recv_up, sup_recv_down;
    std::vector<double> sup_send_up, sup_send_down;
    std::vector<double> reconstructed_up, reconstructed_down;

    MPI_Request halo_rr_up = MPI_REQUEST_NULL, halo_rr_down = MPI_REQUEST_NULL;
    MPI_Request halo_sr_up = MPI_REQUEST_NULL, halo_sr_down = MPI_REQUEST_NULL;
    MPI_Request sup_rr_up = MPI_REQUEST_NULL, sup_rr_down = MPI_REQUEST_NULL;
    MPI_Request sup_sr_up = MPI_REQUEST_NULL, sup_sr_down = MPI_REQUEST_NULL;
    bool rec_up = false, rec_down = false;

    void resize(int nx) {
        halo_recv_up.assign(nx, 0.0); halo_recv_down.assign(nx, 0.0);
        halo_send_up.assign(nx, 0.0); halo_send_down.assign(nx, 0.0);
        // suporte: [ghost_esq_da_fronteira, linha_profunda(nx), ghost_dir_da_fronteira]
        sup_recv_up.assign(nx + 2, 0.0); sup_recv_down.assign(nx + 2, 0.0);
        sup_send_up.assign(nx + 2, 0.0); sup_send_down.assign(nx + 2, 0.0);
        reconstructed_up.assign(nx, 0.0); reconstructed_down.assign(nx, 0.0);
    }
};

inline void wait_req(MPI_Request& r, Stats& st, bool count_cleanup) {
    if (r == MPI_REQUEST_NULL) return;
    const double t0 = MPI_Wtime();
    MPI_Wait(&r, MPI_STATUS_IGNORE);
    const double dt = MPI_Wtime() - t0;
    if (count_cleanup && dt > 0.0) {
        st.cleanup_wait_s += dt;
        st.cleanup_waits++;
    }
}

inline void validate_if_needed(RemoteSlot& s, Stats& st, bool validate) {
    if (!validate) return;
    if (s.rec_up && s.halo_rr_up == MPI_REQUEST_NULL) {
        for (size_t k = 0; k < s.halo_recv_up.size(); ++k)
            st.late_validation_max = std::max(st.late_validation_max, std::abs(s.halo_recv_up[k] - s.reconstructed_up[k]));
        s.rec_up = false;
    }
    if (s.rec_down && s.halo_rr_down == MPI_REQUEST_NULL) {
        for (size_t k = 0; k < s.halo_recv_down.size(); ++k)
            st.late_validation_max = std::max(st.late_validation_max, std::abs(s.halo_recv_down[k] - s.reconstructed_down[k]));
        s.rec_down = false;
    }
}

inline void complete_slot(RemoteSlot& s, Stats& st, bool validate, bool count_cleanup) {
    // Recebimentos tardios primeiro; depois podemos validar a reconstrução.
    wait_req(s.halo_rr_up, st, count_cleanup);
    wait_req(s.halo_rr_down, st, count_cleanup);
    validate_if_needed(s, st, validate);
    wait_req(s.sup_rr_up, st, count_cleanup);
    wait_req(s.sup_rr_down, st, count_cleanup);
    wait_req(s.halo_sr_up, st, count_cleanup);
    wait_req(s.halo_sr_down, st, count_cleanup);
    wait_req(s.sup_sr_up, st, count_cleanup);
    wait_req(s.sup_sr_down, st, count_cleanup);
    s.step = -1;
}

inline void copy_row_to_vec(const Grid& u, int i, std::vector<double>& v) {
    for (int j = 1; j <= u.nx; ++j) v[j - 1] = u(i, j);
}

inline void copy_vec_to_ghost(Grid& u, int ghost_i, const std::vector<double>& v) {
    for (int j = 1; j <= u.nx; ++j) u(ghost_i, j) = v[j - 1];
}

inline double exact_value(double x, double y, double t, double alpha) {
    constexpr double pi = 3.141592653589793238462643383279502884;

    // Problema multimodal:
    // u(x,y,0) = sin(pi x) sin(pi y)
    //            + 0.25 sin(3 pi x) sin(2 pi y)
    //
    // Para u_t = alpha (u_xx + u_yy), os autovalores contínuos são
    // -2 pi^2 para o modo (1,1) e -13 pi^2 para o modo (3,2).
    const double mode11 =
        std::sin(pi * x) * std::sin(pi * y) *
        std::exp(-2.0 * pi * pi * alpha * t);

    const double mode32 =
        0.25 * std::sin(3.0 * pi * x) * std::sin(2.0 * pi * y) *
        std::exp(-13.0 * pi * pi * alpha * t);

    return mode11 + mode32;
}

struct Solver {
    Config cfg;
    Topology topo;
    MPI_Comm world = MPI_COMM_WORLD;
    bool adaptive = false;

    Block bx, by;
    int nx = 0, ny = 0;
    double dx = 0.0, dy = 0.0, dt = 0.0, rx = 0.0, ry = 0.0;
    Grid u, v;

    std::vector<double> xsend_l, xsend_r, xrecv_l, xrecv_r;
    std::vector<double> prev_remote_up, prev_remote_down;
    bool have_prev_up = false, have_prev_down = false;

    // Historico de halos REAIS para o predictor:
    // n1 = mais recente; n2 = imediatamente anterior.
    std::vector<double> pred_real_n1_up, pred_real_n2_up;
    std::vector<double> pred_real_n1_down, pred_real_n2_down;
    std::vector<double> pred_work_up, pred_work_down;
    int pred_step_n1_up = -1, pred_step_n2_up = -1;
    int pred_step_n1_down = -1, pred_step_n2_down = -1;
    std::array<RemoteSlot, RING> slots;
    Stats stats;
    Ewma ewma_wait_up, ewma_wait_down, ewma_rec_up, ewma_rec_down;

    explicit Solver(const Config& c, bool adaptive_) : cfg(c), topo(build_topology(MPI_COMM_WORLD)), adaptive(adaptive_) {
        bx = split_block(cfg.nx_global, topo.local_size, topo.px);
        by = split_block(cfg.ny_global, topo.num_nodes, topo.py);
        nx = bx.n; ny = by.n;
        if (nx < 2 || ny < 3) {
            if (topo.world_rank == 0)
                std::cerr << "ERRO: subdomínio pequeno demais. Use Nx >= 2*Px e Ny >= 3*Py.\n";
            MPI_Abort(world, 5);
        }

        dx = 1.0 / static_cast<double>(cfg.nx_global + 1);
        dy = 1.0 / static_cast<double>(cfg.ny_global + 1);
        // alpha*dt*(1/dx^2 + 1/dy^2) <= 1/2
        dt = cfg.cfl * 0.5 / (cfg.alpha * (1.0/(dx*dx) + 1.0/(dy*dy)));
        rx = cfg.alpha * dt / (dx * dx);
        ry = cfg.alpha * dt / (dy * dy);

        u = Grid(ny, nx);
        v = Grid(ny, nx);
        xsend_l.assign(ny, 0.0); xsend_r.assign(ny, 0.0);
        xrecv_l.assign(ny, 0.0); xrecv_r.assign(ny, 0.0);
        prev_remote_up.assign(nx, 0.0); prev_remote_down.assign(nx, 0.0);
        pred_real_n1_up.assign(nx, 0.0);
        pred_real_n2_up.assign(nx, 0.0);
        pred_real_n1_down.assign(nx, 0.0);
        pred_real_n2_down.assign(nx, 0.0);
        pred_work_up.assign(nx, 0.0);
        pred_work_down.assign(nx, 0.0);
        for (auto& s : slots) s.resize(nx);

        initialize();
    }

    ~Solver() {
        if (topo.local_comm != MPI_COMM_NULL) MPI_Comm_free(&topo.local_comm);
    }

    void initialize() {
        constexpr double pi = 3.141592653589793238462643383279502884;
        for (int i = 1; i <= ny; ++i) {
            const int gy = by.start + (i - 1);
            const double y = (gy + 1) * dy;
            for (int j = 1; j <= nx; ++j) {
                const int gx = bx.start + (j - 1);
                const double x = (gx + 1) * dx;

                // Condição inicial multimodal. Os dois modos satisfazem
                // contorno de Dirichlet homogêneo no domínio [0,1] x [0,1].
                u(i,j) =
                    std::sin(pi*x) * std::sin(pi*y)
                    + 0.25 * std::sin(3.0*pi*x) * std::sin(2.0*pi*y);
            }
        }
        // v começa zerado; após o primeiro swap conterá u^0 e servirá ao primeiro RECOMPUTE.
    }

    inline double update_point(const Grid& g, int i, int j) const {
        const double c = g(i,j);
        return c + rx * (g(i,j-1) - 2.0*c + g(i,j+1))
                 + ry * (g(i-1,j) - 2.0*c + g(i+1,j));
    }

    void post_x_exchange(std::array<MPI_Request,4>& reqs) {
        reqs.fill(MPI_REQUEST_NULL);
        if (topo.left != MPI_PROC_NULL) {
            for (int i=1;i<=ny;++i) xsend_l[i-1]=u(i,1);
            MPI_Irecv(xrecv_l.data(), ny, MPI_DOUBLE, topo.left, TAG_X_TO_RIGHT, world, &reqs[0]);
            MPI_Isend(xsend_l.data(), ny, MPI_DOUBLE, topo.left, TAG_X_TO_LEFT, world, &reqs[1]);
        } else {
            for (int i=1;i<=ny;++i) u(i,0)=0.0;
        }
        if (topo.right != MPI_PROC_NULL) {
            for (int i=1;i<=ny;++i) xsend_r[i-1]=u(i,nx);
            MPI_Irecv(xrecv_r.data(), ny, MPI_DOUBLE, topo.right, TAG_X_TO_LEFT, world, &reqs[2]);
            MPI_Isend(xsend_r.data(), ny, MPI_DOUBLE, topo.right, TAG_X_TO_RIGHT, world, &reqs[3]);
        } else {
            for (int i=1;i<=ny;++i) u(i,nx+1)=0.0;
        }
    }

    void finish_x_exchange(std::array<MPI_Request,4>& reqs) {
        MPI_Waitall(4, reqs.data(), MPI_STATUSES_IGNORE);
        if (topo.left != MPI_PROC_NULL)
            for (int i=1;i<=ny;++i) u(i,0)=xrecv_l[i-1];
        if (topo.right != MPI_PROC_NULL)
            for (int i=1;i<=ny;++i) u(i,nx+1)=xrecv_r[i-1];
    }

    void post_remote_halo(RemoteSlot& s, int step) {
        s.step = step; s.rec_up = s.rec_down = false;
        if (topo.up != MPI_PROC_NULL) {
            copy_row_to_vec(u, 1, s.halo_send_up);
            MPI_Irecv(s.halo_recv_up.data(), nx, MPI_DOUBLE, topo.up, TAG_Y_TO_DOWN, world, &s.halo_rr_up);
            MPI_Isend(s.halo_send_up.data(), nx, MPI_DOUBLE, topo.up, TAG_Y_TO_UP, world, &s.halo_sr_up);
            if (adaptive)
                MPI_Irecv(s.sup_recv_up.data(), nx+2, MPI_DOUBLE, topo.up, TAG_SUP_TO_DOWN, world, &s.sup_rr_up);
        } else {
            for (int j=1;j<=nx;++j) u(0,j)=0.0;
        }
        if (topo.down != MPI_PROC_NULL) {
            copy_row_to_vec(u, ny, s.halo_send_down);
            MPI_Irecv(s.halo_recv_down.data(), nx, MPI_DOUBLE, topo.down, TAG_Y_TO_UP, world, &s.halo_rr_down);
            MPI_Isend(s.halo_send_down.data(), nx, MPI_DOUBLE, topo.down, TAG_Y_TO_DOWN, world, &s.halo_sr_down);
            if (adaptive)
                MPI_Irecv(s.sup_recv_down.data(), nx+2, MPI_DOUBLE, topo.down, TAG_SUP_TO_UP, world, &s.sup_rr_down);
        } else {
            for (int j=1;j<=nx;++j) u(ny+1,j)=0.0;
        }
    }

    void post_support(RemoteSlot& s) {
        if (!adaptive) return;
        if (topo.up != MPI_PROC_NULL) {
            // Para o vizinho de cima: fronteira local i=1; linha profunda i=2.
            s.sup_send_up[0] = u(1,0);
            for (int j=1;j<=nx;++j) s.sup_send_up[j] = u(2,j);
            s.sup_send_up[nx+1] = u(1,nx+1);
            MPI_Isend(s.sup_send_up.data(), nx+2, MPI_DOUBLE, topo.up, TAG_SUP_TO_UP, world, &s.sup_sr_up);
        }
        if (topo.down != MPI_PROC_NULL) {
            // Para o vizinho de baixo: fronteira local i=ny; linha profunda i=ny-1.
            s.sup_send_down[0] = u(ny,0);
            for (int j=1;j<=nx;++j) s.sup_send_down[j] = u(ny-1,j);
            s.sup_send_down[nx+1] = u(ny,nx+1);
            MPI_Isend(s.sup_send_down.data(), nx+2, MPI_DOUBLE, topo.down, TAG_SUP_TO_DOWN, world, &s.sup_sr_down);
        }
    }

    void compute_strict_interior() {
        for (int i=2;i<=ny-1;++i)
            for (int j=2;j<=nx-1;++j)
                v(i,j)=update_point(u,i,j);
    }

    void compute_side_columns() {
        for (int i=2;i<=ny-1;++i) {
            v(i,1)=update_point(u,i,1);
            if (nx > 1) v(i,nx)=update_point(u,i,nx);
        }
    }

    void compute_y_boundaries() {
        for (int j=1;j<=nx;++j) v(1,j)=update_point(u,1,j);
        if (ny > 1)
            for (int j=1;j<=nx;++j) v(ny,j)=update_point(u,ny,j);
    }

    bool policy_recompute(const Ewma& ew_wait, const Ewma& ew_rec) const {
        if (cfg.policy == "wait") return false;
        if (cfg.policy == "always") return true;
        // Fase de bootstrap: recomputa para adquirir amostras de C_R.
        if (!ew_rec.initialized) return true;
        // Sem histórico de WAIT exposto, ainda tentamos RECOMPUTE; o experimento mede o resultado.
        if (!ew_wait.initialized) return true;
        return ew_wait.value > cfg.beta * ew_rec.value;
    }

    void reconstruct_up(const RemoteSlot& prev, RemoteSlot& cur, int step) {
        (void)step;
        const double t0 = MPI_Wtime();
        const auto& sup = prev.sup_recv_up;
        for (int j=1;j<=nx;++j) {
            const double c = prev_remote_up[j-1];
            const double l = (j==1)  ? sup[0]     : prev_remote_up[j-2];
            const double r = (j==nx) ? sup[nx+1] : prev_remote_up[j];
            const double deep = sup[j];
            const double own_prev = v(1,j); // v ainda contém u^{n-1} nesta linha.
            const double val = c + rx*(l - 2.0*c + r) + ry*(deep - 2.0*c + own_prev);
            cur.reconstructed_up[j-1] = val;
            u(0,j)=val;
        }
        const double dtc = MPI_Wtime()-t0;
        stats.recompute_s += dtc; stats.recomputes++;
        ewma_rec_up.add(dtc);
        cur.rec_up = true;
        prev_remote_up = cur.reconstructed_up;
        have_prev_up = true;
    }

    void reconstruct_down(const RemoteSlot& prev, RemoteSlot& cur, int step) {
        (void)step;
        const double t0 = MPI_Wtime();
        const auto& sup = prev.sup_recv_down;
        for (int j=1;j<=nx;++j) {
            const double c = prev_remote_down[j-1];
            const double l = (j==1)  ? sup[0]     : prev_remote_down[j-2];
            const double r = (j==nx) ? sup[nx+1] : prev_remote_down[j];
            const double deep = sup[j];
            const double own_prev = v(ny,j);
            const double val = c + rx*(l - 2.0*c + r) + ry*(deep - 2.0*c + own_prev);
            cur.reconstructed_down[j-1] = val;
            u(ny+1,j)=val;
        }
        const double dtc = MPI_Wtime()-t0;
        stats.recompute_s += dtc; stats.recomputes++;
        ewma_rec_down.add(dtc);
        cur.rec_down = true;
        prev_remote_down = cur.reconstructed_down;
        have_prev_down = true;
    }

    void record_real_up(int step, const std::vector<double>& halo) {
        pred_real_n2_up = pred_real_n1_up;
        pred_step_n2_up = pred_step_n1_up;
        pred_real_n1_up = halo;
        pred_step_n1_up = step;
    }

    void record_real_down(int step, const std::vector<double>& halo) {
        pred_real_n2_down = pred_real_n1_down;
        pred_step_n2_down = pred_step_n1_down;
        pred_real_n1_down = halo;
        pred_step_n1_down = step;
    }

    bool make_predict_up(int step) {
        // O predictor precisa de dois halos REAIS anteriores.
        // step=0 nao possui historico; step=1 possui apenas o halo do step=0.
        if (step < 2)
            return false;
        if (pred_step_n1_up != step - 1 || pred_step_n2_up != step - 2)
            return false;
        for (int j = 0; j < nx; ++j)
            pred_work_up[j] = 2.0 * pred_real_n1_up[j] - pred_real_n2_up[j];
        return true;
    }

    bool make_predict_down(int step) {
        // O predictor precisa de dois halos REAIS anteriores.
        // step=0 nao possui historico; step=1 possui apenas o halo do step=0.
        if (step < 2)
            return false;
        if (pred_step_n1_down != step - 1 || pred_step_n2_down != step - 2)
            return false;
        for (int j = 0; j < nx; ++j)
            pred_work_down[j] = 2.0 * pred_real_n1_down[j] - pred_real_n2_down[j];
        return true;
    }

    void validate_predict(const std::vector<double>& predicted,
                          const std::vector<double>& real) {
        double linf = 0.0;
        for (int j = 0; j < nx; ++j)
            linf = std::max(linf, std::abs(predicted[j] - real[j]));
        stats.predict_tests++;
        stats.predict_linf_sum += linf;
        stats.predict_linf_max = std::max(stats.predict_linf_max, linf);
    }

    void acquire_up(RemoteSlot& cur, RemoteSlot* prev, int step) {
        if (topo.up == MPI_PROC_NULL) return;
        int ready=0;
        MPI_Test(&cur.halo_rr_up, &ready, MPI_STATUS_IGNORE);
        if (ready) {
            copy_vec_to_ghost(u,0,cur.halo_recv_up);
            record_real_up(step, cur.halo_recv_up);
            prev_remote_up=cur.halo_recv_up; have_prev_up=true; stats.reads++;
            return;
        }

        if (adaptive && step>0 && prev && have_prev_up) {
            int sup_ready=0;
            MPI_Test(&prev->sup_rr_up, &sup_ready, MPI_STATUS_IGNORE);
            if (sup_ready && policy_recompute(ewma_wait_up, ewma_rec_up)) {
                reconstruct_up(*prev,cur,step);
                return;
            }
            if (!sup_ready) stats.support_unavailable++;
        }

        // Diagnostico: calcula a extrapolacao somente quando o halo ainda
        // nao chegou. A solucao continua aguardando e usando o halo REAL.
        const bool pred_ok = make_predict_up(step);

        const double t0=MPI_Wtime();
        MPI_Wait(&cur.halo_rr_up,MPI_STATUS_IGNORE);
        const double w=MPI_Wtime()-t0;
        stats.wait_s += w; stats.waits++; ewma_wait_up.add(w);

        if (pred_ok) validate_predict(pred_work_up, cur.halo_recv_up);

        copy_vec_to_ghost(u,0,cur.halo_recv_up);
        record_real_up(step, cur.halo_recv_up);
        prev_remote_up=cur.halo_recv_up; have_prev_up=true;
    }

    void acquire_down(RemoteSlot& cur, RemoteSlot* prev, int step) {
        if (topo.down == MPI_PROC_NULL) return;
        int ready=0;
        MPI_Test(&cur.halo_rr_down, &ready, MPI_STATUS_IGNORE);
        if (ready) {
            copy_vec_to_ghost(u,ny+1,cur.halo_recv_down);
            record_real_down(step, cur.halo_recv_down);
            prev_remote_down=cur.halo_recv_down; have_prev_down=true; stats.reads++;
            return;
        }

        if (adaptive && step>0 && prev && have_prev_down) {
            int sup_ready=0;
            MPI_Test(&prev->sup_rr_down, &sup_ready, MPI_STATUS_IGNORE);
            if (sup_ready && policy_recompute(ewma_wait_down, ewma_rec_down)) {
                reconstruct_down(*prev,cur,step);
                return;
            }
            if (!sup_ready) stats.support_unavailable++;
        }

        // Diagnostico: calcula a extrapolacao somente quando o halo ainda
        // nao chegou. A solucao continua aguardando e usando o halo REAL.
        const bool pred_ok = make_predict_down(step);

        const double t0=MPI_Wtime();
        MPI_Wait(&cur.halo_rr_down,MPI_STATUS_IGNORE);
        const double w=MPI_Wtime()-t0;
        stats.wait_s += w; stats.waits++; ewma_wait_down.add(w);

        if (pred_ok) validate_predict(pred_work_down, cur.halo_recv_down);

        copy_vec_to_ghost(u,ny+1,cur.halo_recv_down);
        record_real_down(step, cur.halo_recv_down);
        prev_remote_down=cur.halo_recv_down; have_prev_down=true;
    }

    std::string variant_name() const {
        if (!adaptive) return "naive";
        if (cfg.policy == "wait") return "support_wait";
        return "recompute";
    }

    bool should_inject(int step) const {
        if (cfg.inject_delay_us<=0 || cfg.inject_every<=0 || cfg.inject_node<0) return false;
        if (topo.node_index != cfg.inject_node) return false;
        if (cfg.inject_local_rank>=0 && topo.local_rank!=cfg.inject_local_rank) return false;
        return (step % cfg.inject_every)==0;
    }

    void run() {
        if (topo.world_rank==0) {
            std::cout << "TOPOLOGY ranks=" << topo.world_size
                      << " nodes=" << topo.num_nodes
                      << " ranks_per_node=" << topo.local_size
                      << " logical_grid=" << topo.num_nodes << "x" << topo.local_size
                      << " variant=" << variant_name() << "\n";
            std::cout << std::setprecision(17)
                      << "PARAM nx=" << cfg.nx_global << " ny=" << cfg.ny_global
                      << " steps=" << cfg.steps << " alpha=" << cfg.alpha
                      << " cfl=" << cfg.cfl << " dt=" << dt
                      << " rx=" << rx << " ry=" << ry
                      << " policy=" << (adaptive?cfg.policy:"wait") << "\n";
        }

        MPI_Barrier(world);
        const double t0 = MPI_Wtime();

        for (int step=0; step<cfg.steps; ++step) {
            RemoteSlot& cur = slots[step % RING];
            if (cur.step >= 0) complete_slot(cur, stats, cfg.validate_late, true);

            if (should_inject(step)) spin_delay_us(cfg.inject_delay_us);

            // 1) Halo inter-nó normal é postado cedo, como no baseline.
            post_remote_halo(cur, step);

            // 2) MPI intra-nó normal esquerda/direita.
            std::array<MPI_Request,4> xreq;
            post_x_exchange(xreq);

            // 3) Trabalho que não depende de halo algum.
            compute_strict_interior();

            // 4) Conclui apenas as dependências intra-nó.
            finish_x_exchange(xreq);

            // 5) No adaptativo, envia suporte para a POSSÍVEL recomputação do próximo passo.
            post_support(cur);

            // 6) Trabalho que depende só de halos intra-nó.
            compute_side_columns();

            // 7) READ | RECOMPUTE | WAIT apenas para os vizinhos inter-nó.
            RemoteSlot* prev = (step>0) ? &slots[(step-1)%RING] : nullptr;
            acquire_up(cur, prev, step);
            acquire_down(cur, prev, step);

            // 8) Agora as linhas de fronteira podem ser avançadas.
            compute_y_boundaries();

            // Sondas baratas: completam requests tardios sem bloquear e permitem validar.
            if (adaptive) {
                int f=0;
                if (cur.rec_up && cur.halo_rr_up!=MPI_REQUEST_NULL) MPI_Test(&cur.halo_rr_up,&f,MPI_STATUS_IGNORE);
                if (cur.rec_down && cur.halo_rr_down!=MPI_REQUEST_NULL) MPI_Test(&cur.halo_rr_down,&f,MPI_STATUS_IGNORE);
                validate_if_needed(cur,stats,cfg.validate_late);
            }

            std::swap(u.a, v.a);
        }

        // Drena tráfego em voo: C_future também faz parte do makespan da variante.
        for (auto& s: slots) if (s.step>=0) complete_slot(s,stats,cfg.validate_late,true);

        const double local_elapsed = MPI_Wtime() - t0;

        // Erro numérico fora da ROI de comunicação; usa a solução já concluída.
        const double tfinal = cfg.steps * dt;
        double local_err2=0.0, local_maxabs=0.0;
        for (int i=1;i<=ny;++i) {
            const int gy=by.start+i-1; const double y=(gy+1)*dy;
            for (int j=1;j<=nx;++j) {
                const int gx=bx.start+j-1; const double x=(gx+1)*dx;
                const double e=std::abs(u(i,j)-exact_value(x,y,tfinal,cfg.alpha));
                local_err2 += e*e; local_maxabs=std::max(local_maxabs,e);
            }
        }

        double makespan=0.0, sum_err2=0.0, maxabs=0.0, late_max=0.0;
        long long global_points = static_cast<long long>(cfg.nx_global) * cfg.ny_global;
        MPI_Reduce(&local_elapsed,&makespan,1,MPI_DOUBLE,MPI_MAX,0,world);
        MPI_Reduce(&local_err2,&sum_err2,1,MPI_DOUBLE,MPI_SUM,0,world);
        MPI_Reduce(&local_maxabs,&maxabs,1,MPI_DOUBLE,MPI_MAX,0,world);
        MPI_Reduce(&stats.late_validation_max,&late_max,1,MPI_DOUBLE,MPI_MAX,0,world);

        long long loc_counts[5]={stats.reads,stats.waits,stats.recomputes,stats.support_unavailable,stats.cleanup_waits};
        long long glob_counts[5]={0,0,0,0,0};
        double loc_times[3]={stats.wait_s,stats.recompute_s,stats.cleanup_wait_s};
        double glob_times[3]={0,0,0};
        MPI_Reduce(loc_counts,glob_counts,5,MPI_LONG_LONG_INT,MPI_SUM,0,world);
        MPI_Reduce(loc_times,glob_times,3,MPI_DOUBLE,MPI_SUM,0,world);

        long long global_predict_tests = 0;
        double global_predict_linf_sum = 0.0;
        double global_predict_linf_max = 0.0;
        MPI_Reduce(&stats.predict_tests, &global_predict_tests, 1,
                   MPI_LONG_LONG_INT, MPI_SUM, 0, world);
        MPI_Reduce(&stats.predict_linf_sum, &global_predict_linf_sum, 1,
                   MPI_DOUBLE, MPI_SUM, 0, world);
        MPI_Reduce(&stats.predict_linf_max, &global_predict_linf_max, 1,
                   MPI_DOUBLE, MPI_MAX, 0, world);

        // ------------------------------------------------------------
        // Instrumentacao de criticidade.
        // Fica fora da regiao cronometrada: local_elapsed ja foi medido.
        // Coleta o tempo individual e a posicao logica de todos os ranks.
        // ------------------------------------------------------------
        std::vector<double> all_elapsed;
        std::vector<int> all_node_index;
        std::vector<int> all_local_rank;

        if (topo.world_rank == 0) {
            all_elapsed.resize(static_cast<std::size_t>(topo.world_size));
            all_node_index.resize(static_cast<std::size_t>(topo.world_size));
            all_local_rank.resize(static_cast<std::size_t>(topo.world_size));
        }

        MPI_Gather(&local_elapsed, 1, MPI_DOUBLE,
                   topo.world_rank == 0 ? all_elapsed.data() : nullptr,
                   1, MPI_DOUBLE, 0, world);

        MPI_Gather(&topo.node_index, 1, MPI_INT,
                   topo.world_rank == 0 ? all_node_index.data() : nullptr,
                   1, MPI_INT, 0, world);

        MPI_Gather(&topo.local_rank, 1, MPI_INT,
                   topo.world_rank == 0 ? all_local_rank.data() : nullptr,
                   1, MPI_INT, 0, world);

        if (topo.world_rank==0) {
            const double l2=std::sqrt(sum_err2/static_cast<double>(global_points));

            std::vector<double> node_max(
                static_cast<std::size_t>(topo.num_nodes),
                -std::numeric_limits<double>::infinity());

            std::vector<int> node_arg_world(
                static_cast<std::size_t>(topo.num_nodes), -1);

            std::vector<int> node_arg_local(
                static_cast<std::size_t>(topo.num_nodes), -1);

            double critical_time =
                -std::numeric_limits<double>::infinity();
            int critical_world = -1;
            int critical_node = -1;
            int critical_local = -1;

            for (int r = 0; r < topo.world_size; ++r) {
                const int n =
                    all_node_index[static_cast<std::size_t>(r)];
                const double tr =
                    all_elapsed[static_cast<std::size_t>(r)];

                if (tr > node_max[static_cast<std::size_t>(n)]) {
                    node_max[static_cast<std::size_t>(n)] = tr;
                    node_arg_world[static_cast<std::size_t>(n)] = r;
                    node_arg_local[static_cast<std::size_t>(n)] =
                        all_local_rank[static_cast<std::size_t>(r)];
                }

                if (tr > critical_time) {
                    critical_time = tr;
                    critical_world = r;
                    critical_node = n;
                    critical_local =
                        all_local_rank[static_cast<std::size_t>(r)];
                }
            }

            std::cout << std::setprecision(12)
                      << "CRITICAL"
                      << " world_rank=" << critical_world
                      << " node=" << critical_node
                      << " local_rank=" << critical_local
                      << " elapsed_s=" << critical_time
                      << " reduce_diff_s="
                      << std::abs(critical_time - makespan)
                      << "\n";

            for (int n = 0; n < topo.num_nodes; ++n) {
                std::cout << std::setprecision(12)
                          << "NODETIME"
                          << " node=" << n
                          << " max_s="
                          << node_max[static_cast<std::size_t>(n)]
                          << " slack_s="
                          << (critical_time -
                              node_max[static_cast<std::size_t>(n)])
                          << " arg_world_rank="
                          << node_arg_world[static_cast<std::size_t>(n)]
                          << " arg_local_rank="
                          << node_arg_local[static_cast<std::size_t>(n)]
                          << "\n";
            }
            std::cout << std::setprecision(12)
                      << "PREDICT_DIAG"
                      << " tests=" << global_predict_tests
                      << " mean_linf_error="
                      << (global_predict_tests > 0
                          ? global_predict_linf_sum / static_cast<double>(global_predict_tests)
                          : 0.0)
                      << " max_linf_error=" << global_predict_linf_max
                      << "\n";

            std::cout << std::setprecision(12)
                      << "RESULT variant=" << variant_name()
                      << " policy=" << (adaptive?cfg.policy:"wait")
                      << " ranks=" << topo.world_size
                      << " nodes=" << topo.num_nodes
                      << " ppn=" << topo.local_size
                      << " nx=" << cfg.nx_global << " ny=" << cfg.ny_global
                      << " steps=" << cfg.steps
                      << " makespan_s=" << makespan
                      << " reads=" << glob_counts[0]
                      << " waits=" << glob_counts[1]
                      << " recomputes=" << glob_counts[2]
                      << " support_unavailable=" << glob_counts[3]
                      << " cleanup_waits=" << glob_counts[4]
                      << " wait_sum_s=" << glob_times[0]
                      << " recompute_sum_s=" << glob_times[1]
                      << " cleanup_wait_sum_s=" << glob_times[2]
                      << " late_validation_max=" << late_max
                      << " l2_error=" << l2
                      << " max_error=" << maxabs
                      << " inject_us=" << cfg.inject_delay_us
                      << " inject_every=" << cfg.inject_every
                      << " inject_node=" << cfg.inject_node
                      << " inject_local_rank=" << cfg.inject_local_rank
                      << "\n";
        }
    }
};

inline int main_impl(int argc, char** argv, bool adaptive) {
    MPI_Init(&argc,&argv);
    int rank=0; MPI_Comm_rank(MPI_COMM_WORLD,&rank);
    int rc=0;
    try {
        Config cfg=parse_args(argc,argv);
        Solver solver(cfg,adaptive);
        solver.run();
    } catch (const std::exception& e) {
        if (rank==0) std::cerr << "ERRO: " << e.what() << "\n";
        rc=1;
    }
    if (rc) MPI_Abort(MPI_COMM_WORLD,rc);
    MPI_Finalize();
    return rc;
}

} // namespace heat2d
