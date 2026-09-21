CXX = mpicxx
CXXFLAGS ?= -O3 -std=c++17 -DNDEBUG
LDFLAGS ?=

CORE_BINS = heat2d_naive heat2d_recompute heat2d_predict heat2d_predict_operational
DIAG_BINS = heat2d_naive_trace heat2d_naive_waittrace heat2d_predict_multimode heat2d_predict_admiss
BINS = $(CORE_BINS) $(DIAG_BINS)

.PHONY: all core diagnostics clean

all: core diagnostics

core: $(CORE_BINS)

diagnostics: $(DIAG_BINS)

heat2d_naive: heat2d_mpi_naive.cpp heat2d_common.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_recompute: heat2d_mpi_recompute.cpp heat2d_common.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_predict: heat2d_mpi_predict.cpp heat2d_common_predict.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_predict_operational: heat2d_mpi_predict_operational.cpp heat2d_common_predict_operational.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_predict_multimode: heat2d_mpi_predict_multimode.cpp heat2d_common_predict_multimode.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_predict_admiss: heat2d_mpi_predict_admiss.cpp heat2d_common_predict_admiss.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_naive_trace: heat2d_mpi_naive_trace.cpp heat2d_common_trace.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_naive_waittrace: heat2d_mpi_naive_waittrace.cpp heat2d_common_waittrace.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

clean:
	rm -f $(BINS)
