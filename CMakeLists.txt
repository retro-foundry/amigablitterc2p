cmake_minimum_required(VERSION 3.20)
project(amigatest NONE)

# Support Debug and Release (and other configs) for multi-config generators
# (e.g. Visual Studio). Outputs go to build/Debug/ and build/Release/.
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS Debug Release RelWithDebInfo MinSizeRel)
endif()

set(VC_COMPILER "vc" CACHE STRING "Path to vbcc 'vc' compiler driver")

# NDK include path so <hardware/custom.h> resolves (vc's +aos68k often only has targets/.../include).
# Set VBCC (env or cache) before configuring; default NDK path is ${VBCC}/NDK_3.5/Include/include_h.
if(NOT VBCC)
  set(VBCC "$ENV{VBCC}" CACHE PATH "vbcc install root (used for NDK include path)")
endif()
set(VBCC_NDK_INCLUDE "" CACHE PATH "Amiga NDK include (e.g. .../NDK_3.5/Include/include_h)")
if(VBCC AND NOT VBCC_NDK_INCLUDE)
  set(VBCC_NDK_INCLUDE "${VBCC}/NDK_3.5/Include/include_h" CACHE PATH "Amiga NDK include" FORCE)
endif()
if(VBCC_NDK_INCLUDE)
  set(AMIGA_NDK_INCLUDE_FLAG "-I${VBCC_NDK_INCLUDE}")
endif()

# vasmm68k_mot is invoked directly for 68020 .s sources because vc's +aos68k
# config hardcodes the assembler call without forwarding -cpu=m68020 to vasm.
# The pre-assembled .o is then handed to vc for linking alongside the C sources.
set(VASM "vasmm68k_mot" CACHE STRING "Path to vasmm68k_mot assembler")

set(AMIGA_COMMON_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main.c
)

function(add_amiga_variant target_name chipset s2p_bench c2p_source render_source)
    set(bin_dir "${CMAKE_CURRENT_BINARY_DIR}")
    set(out_debug "${bin_dir}/Debug/${target_name}")
    set(out_release "${bin_dir}/Release/${target_name}")

    if(chipset STREQUAL "AGA")
        get_filename_component(render_name "${render_source}" NAME_WE)
        set(obj_debug "${bin_dir}/Debug/${render_name}.o")
        set(obj_release "${bin_dir}/Release/${render_name}.o")

        # Separate command per config so OUTPUT matches what is actually created.
        add_custom_command(
            OUTPUT "${obj_debug}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${bin_dir}/Debug"
            COMMAND ${VASM}
                    -m68020 -Fhunk -quiet -nowarn=62
                    "${render_source}" -o "${obj_debug}"
            DEPENDS "${render_source}"
            VERBATIM
            COMMENT "Assembling ${render_name} (68020) [Debug]"
        )
        add_custom_command(
            OUTPUT "${obj_release}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${bin_dir}/Release"
            COMMAND ${VASM}
                    -m68020 -Fhunk -quiet -nowarn=62
                    "${render_source}" -o "${obj_release}"
            DEPENDS "${render_source}"
            VERBATIM
            COMMENT "Assembling ${render_name} (68020) [Release]"
        )

        set(sources_debug  ${AMIGA_COMMON_SOURCES} ${c2p_source} "${obj_debug}")
        set(sources_release ${AMIGA_COMMON_SOURCES} ${c2p_source} "${obj_release}")
    else()
        set(sources_common ${AMIGA_COMMON_SOURCES} ${render_source} ${c2p_source})
        set(sources_debug  ${sources_common})
        set(sources_release ${sources_common})
    endif()

    add_custom_command(
        OUTPUT "${out_debug}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${bin_dir}/Debug"
        COMMAND ${VC_COMPILER}
                +aos68k ${sources_debug}
                -O0
                -DS2P_BENCH_ONLY=${s2p_bench}
                -DAMIGA_CHIPSET_${chipset}=1
                ${AMIGA_NDK_INCLUDE_FLAG}
                -o "${out_debug}"
                -lamiga
        DEPENDS ${sources_debug}
        WORKING_DIRECTORY ${bin_dir}
        VERBATIM
        COMMENT "Building ${target_name} (${chipset}) [Debug]"
    )
    add_custom_command(
        OUTPUT "${out_release}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${bin_dir}/Release"
        COMMAND ${VC_COMPILER}
                +aos68k ${sources_release}
                -O3
                -DS2P_BENCH_ONLY=${s2p_bench}
                -DAMIGA_CHIPSET_${chipset}=1
                ${AMIGA_NDK_INCLUDE_FLAG}
                -o "${out_release}"
                -lamiga
        DEPENDS ${sources_release}
        WORKING_DIRECTORY ${bin_dir}
        VERBATIM
        COMMENT "Building ${target_name} (${chipset}) [Release]"
    )

    add_custom_target(${target_name} ALL DEPENDS "${out_debug}" "${out_release}")
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
