#include "heat2d_common_predict_admiss.hpp"

int main(int argc, char** argv) {
    // true ativa apenas o trafego de suporte; --policy wait e obrigatorio
    // e e imposto pelo proprio diagnostico.
    return heat2d::main_impl(argc, argv, true);
}
