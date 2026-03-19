cmake_minimum_required(VERSION 3.20)
project(amigatest NONE)

set(VC_COMPILER "vc" CACHE STRING "Path to vbcc 'vc' compiler driver")

set(AMIGA_COMMON_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main.c
)

function(add_amiga_variant target_name chipset s2p_bench c2p_source render_source)
    set(AMIGA_SOURCES
        ${AMIGA_COMMON_SOURCES}
        ${render_source}
        ${c2p_source}
    )
    set(output_file ${CMAKE_CURRENT_BINARY_DIR}/${target_name})

    add_custom_command(
        OUTPUT ${output_file}
        COMMAND ${VC_COMPILER}
                +aos68k
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

# ECS: blitter-assisted C2P path, S2P benchmark mode enabled.
add_amiga_variant(
    demo_ecs
    ECS
    1
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
