project_name := "huginn"
os_name := os()

server_dir := "server"
bin_dir := "bin"
debug_bin_dir := bin_dir / "debug"
release_bin_dir := bin_dir / "release"

debug_executable := debug_bin_dir / project_name + "_" + os_name
release_executable := release_bin_dir / project_name + "_" + os_name

strict_flags := "-vet -strict-style -vet-tabs -disallow-do -warnings-as-errors"
debug_flags := "-debug -o:none " + strict_flags
release_flags := "-o:speed " + strict_flags

# ---------------------------------------------------------------------------------------

# Build debug
[group('build')]
build-debug:
    mkdir -p {{ debug_bin_dir }}
    odin build {{ server_dir }}/ -out:{{ debug_executable }} {{ debug_flags }}
alias bd := build-debug

# Build release
[group('build')]
build-release:
    mkdir -p {{ release_bin_dir }}
    odin build {{ server_dir }}/ -out:{{ release_executable }} {{ release_flags }}
alias br := build-release

# ---------------------------------------------------------------------------------------

# Run server (debug build) on port 8080
[group('run')]
run-debug:
    ./{{ debug_executable }}
alias rd := run-debug

# Run server (release build) on port 8080
[group('run')]
run-release:
    ./{{ release_executable }}
alias rr := run-release

# ---------------------------------------------------------------------------------------

# Remove bin/
[group('clean')]
clean:
    rm -rf {{ bin_dir }}
alias c := clean
