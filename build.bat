@echo off
setlocal

cmake -S . -B build || exit /b 1
cmake --build build --target demo_ecs --config Release || exit /b 1
cmake --build build --target demo_aga --config Release || exit /b 1
echo Built build\Release\demo_ecs
echo Built build\Release\demo_aga
