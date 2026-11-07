const std = @import("std");

const notice_sh =
    \\echo
    \\echo "dkscripture installed."
    \\if ! command -v dkscripture >/dev/null 2>&1; then
    \\  echo "NOTE: dkscripture is not on your PATH yet. If you installed with -p ~/.local,"
    \\  echo "add this to your shell startup file (bash: ~/.bashrc, zsh: ~/.zshrc):"
    \\  echo '  export PATH="$HOME/.local/bin:$PATH"'
    \\  echo
    \\fi
    \\rc="$HOME/.bashrc"
    \\hook='command -v dkscripture >/dev/null && dkscripture'
    \\if [ -f "$rc" ] && grep -qF "$hook" "$rc"; then
    \\  echo "Login hook already in $rc."
    \\else
    \\  printf '\n# dkscripture: show a quote at login\n%s\n' "$hook" >> "$rc" &&
    \\    echo "Added login hook to $rc. Run: source ~/.bashrc" ||
    \\    echo "Could not write $rc; add this line yourself: $hook"
    \\fi
    \\echo
    \\echo "Other shells: add the same line to ~/.zshrc (then: source ~/.zshrc),"
    \\echo "or for fish, to ~/.config/fish/config.fish as:"
    \\echo "  command -q dkscripture; and dkscripture"
    \\echo
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default: safe)") orelse .safe;

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The finished quote database is built into the program, so nothing has to
    // be downloaded. `dkscripture fetch` can still rebuild it from newer sources.
    root.addAnonymousImport("quotes.tsv", .{ .root_source_file = b.path("data/quotes.tsv") });
    const exe = b.addExecutable(.{
        .name = "dkscripture",
        .root_module = root,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // After installing, add the login hook to ~/.bashrc (once) and print setup
    // notes for PATH and other shells. POSIX sh only; skipped on Windows.
    if (b.graph.host.result.os.tag != .windows) {
        const notice = b.addSystemCommand(&.{ "sh", "-c", notice_sh });
        notice.has_side_effects = true;
        notice.stdio = .inherit;
        notice.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&notice.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run dkscripture").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
