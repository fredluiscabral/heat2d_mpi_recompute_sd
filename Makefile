CXX = mpicxx
CXXFLAGS ?= -O3 -std=c++17 -DNDEBUG
LDFLAGS ?=

CORE_BINS = heat2d_naive heat2d_recompute heat2d_predict
DIAG_BINS = heat2d_naive_trace heat2d_naive_waittrace
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

heat2d_naive_trace: heat2d_mpi_naive_trace.cpp heat2d_common_trace.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

heat2d_naive_waittrace: heat2d_mpi_naive_waittrace.cpp heat2d_common_waittrace.hpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDFLAGS)

clean:
	rm -f $(BINS)
