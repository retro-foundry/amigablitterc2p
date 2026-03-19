@echo off
setlocal

cmake -S . -B build || exit /b 1
cmake --build build --target demo_ecs || exit /b 1
cmake --build build --target demo_aga || exit /b 1
echo Built build\demo_ecs
