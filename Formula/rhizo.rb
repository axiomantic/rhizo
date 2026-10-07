class Rhizo < Formula
  desc "Inter-assistant Redis bus & multi-agent coordination mesh without background daemons"
  homepage "https://github.com/axiomantic/rhizo"
  version "0.2.6"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/axiomantic/rhizo/releases/download/v#{version}/rhizo-darwin-arm64.tar.gz"
      sha256 "REPLACE_WITH_DARWIN_ARM64_SHA"
    else
      url "https://github.com/axiomantic/rhizo/releases/download/v#{version}/rhizo-darwin-amd64.tar.gz"
      sha256 "REPLACE_WITH_DARWIN_AMD64_SHA"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/axiomantic/rhizo/releases/download/v#{version}/rhizo-linux-arm64.tar.gz"
      sha256 "REPLACE_WITH_LINUX_ARM64_SHA"
    else
      url "https://github.com/axiomantic/rhizo/releases/download/v#{version}/rhizo-linux-amd64.tar.gz"
      sha256 "REPLACE_WITH_LINUX_AMD64_SHA"
    end
  end

  head "https://github.com/axiomantic/rhizo.git", branch: "main"

  depends_on "nim" => :build if build.head?
  depends_on "redis" => :recommended

  def install
    if build.head?
      system "nim", "c", "-d:release", "--opt:speed", "-o:bin/rhizo", "src/rhizo.nim"
      bin.install "bin/rhizo"
    else
      bin.install "rhizo"
    end
    pkgshare.install "skills" if File.exist?("skills")
  end

  def caveats
    <<~EOS
      To equip your AI coding assistants (Claude Code, Antigravity, OpenCode, Cursor):
        npx skills add axiomantic/rhizo -g
        # Or using skilz:
        skilz install https://github.com/axiomantic/rhizo
        # Or offline from local Homebrew files:
        npx skills add #{opt_pkgshare}/skills/rhizo -g
    EOS
  end

  test do
    assert_match "Nim Native", shell_output("#{bin}/rhizo --help")
  end
end
