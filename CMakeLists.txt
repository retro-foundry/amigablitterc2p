cmake_minimum_required(VERSION 3.20)
project(amigatest NONE)

set(VC_COMPILER "vc" CACHE STRING "Path to vbcc 'vc' compiler driver")

# vasmm68k_mot is invoked directly for 68020 .s sources because vc's +aos68k
# config hardcodes the assembler call without forwarding -cpu=m68020 to vasm.
# The pre-assembled .o is then handed to vc for linking alongside the C sources.
set(VASM "vasmm68k_mot" CACHE STRING "Path to vasmm68k_mot assembler")

set(AMIGA_COMMON_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main.c
)

function(add_amiga_variant target_name chipset s2p_bench c2p_source render_source)
    set(output_file ${CMAKE_CURRENT_BINARY_DIR}/${target_name})

    if(chipset STREQUAL "AGA")
        # Assemble the 68020 render source directly so we can pass -m68020.
        # vc's +aos68k profile never forwards the CPU flag to its vasm call.
        get_filename_component(render_name "${render_source}" NAME_WE)
        set(render_obj "${CMAKE_CURRENT_BINARY_DIR}/${render_name}.o")

        add_custom_command(
            OUTPUT  "${render_obj}"
            COMMAND ${VASM}
                    -m68020
                    -Fhunk
                    -quiet
                    -nowarn=62
                    "${render_source}"
                    -o "${render_obj}"
            DEPENDS "${render_source}"
            VERBATIM
            COMMENT "Assembling ${render_name} (68020)"
        )

        set(AMIGA_SOURCES
            ${AMIGA_COMMON_SOURCES}
            ${c2p_source}
            "${render_obj}"
        )
        # Do NOT pass -cpu=m68020 to vc: vbccm68k internal-errors on it.
        # The render .s is already assembled as 68020 above; C stays 68000.
        set(CPU_FLAGS)
    else()
        set(AMIGA_SOURCES
            ${AMIGA_COMMON_SOURCES}
            ${render_source}
            ${c2p_source}
        )
        set(CPU_FLAGS)
    endif()

    add_custom_command(
        OUTPUT ${output_file}
        COMMAND ${VC_COMPILER}
                +aos68k
                ${CPU_FLAGS}
                ${AMIGA_SOURCES}
                -O3
                -DS2P_BENCH_ONLY=${s2p_bench}
                -DAMIGA_CHIPSET_${chipset}=1
                -o ${output_file}
                -lamiga
        DEPENDS ${AMIGA_SOURCES}
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        VERBATIM
        COMMENT "Building ${target_name} (${chipset})"
    )

    add_custom_target(${target_name} ALL DEPENDS ${output_file})
endfunction()

# ECS: blitter-assisted C2P path with normal per-frame drawing enabled.
add_amiga_variant(
    demo_ecs
    ECS
    0
    ${CMAKE_CURRENT_SOURCE_DIR}/src/c2p_blit_4bpl_stretched_local.s
    ${CMAKE_CURRENT_SOURCE_DIR}/src/render_chunky_span_asm.s
)

# AGA: blitter-assisted C2P path with AGA-specific blit-size optimization.
add_amiga_variant(
    demo_aga
    AGA
    0
    ${CMAKE_CURRENT_SOURCE_DIR}/src/c2p_blit_4bpl_stretched_aga.s
    ${CMAKE_CURRENT_SOURCE_DIR}/src/render_chunky_span_asm_020.s
)
