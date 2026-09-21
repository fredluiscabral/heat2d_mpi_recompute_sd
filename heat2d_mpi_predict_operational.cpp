#include "heat2d_common_predict_operational.hpp"

int main(int argc, char** argv) {
    // true habilita o trafego de suporte quando --enable-predict 1.
    // --enable-predict 0 desliga esse trafego e executa READ/WAIT puro.
    return heat2d::main_impl(argc, argv, true);
}
