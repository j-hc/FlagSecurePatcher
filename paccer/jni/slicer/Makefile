SLICER_SRCS := \
    bytecode_encoder.cc \
    code_ir.cc \
    common.cc \
    control_flow_graph.cc \
    debuginfo_encoder.cc \
    dex_bytecode.cc \
    dex_format.cc \
    dex_ir.cc \
    dex_ir_builder.cc \
    dex_utf8.cc \
    instrumentation.cc \
    reader.cc \
    tryblocks_encoder.cc \
    writer.cc

SLICER_INCLUDES := -I./export
SLICER_CFLAGS := \
    -ggdb \
    -Wall \
    -Wno-sign-compare \
    -Wno-unused-parameter \
    -Wno-shift-count-overflow \
    -Wno-missing-braces

SLICER_LIBS := -lz

libslicer.a: $(SLICER_SRCS)
	g++ -std=c++17 -fno-rtti -static $(SLICER_CFLAGS) $(SLICER_INCLUDES) -c $(SLICER_SRCS)
	ar rcs $@ *.o
	rm -f *.o

.PHONY: all clean

all: libslice.so

clean:
	rm -f *.o libslice.so
