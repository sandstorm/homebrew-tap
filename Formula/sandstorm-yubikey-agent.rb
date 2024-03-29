# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class SandstormYubikeyAgent < Formula
  desc ""
  homepage "https://github.com/sandstorm/yubikey-agent"
  version "0.1.5-p7"
  depends_on :macos

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/yubikey-agent/releases/download/v0.1.5-p7/yubikey-agent_0.1.5-p7_Darwin_arm64.tar.gz"
      sha256 "e7df89cc2ed4f7f889d92f3cc8187153cdab569761e80d61cd47f77ba0d624cf"

      def install
        bin.install "yubikey-agent"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/yubikey-agent/releases/download/v0.1.5-p7/yubikey-agent_0.1.5-p7_Darwin_x86_64.tar.gz"
      sha256 "4ccf40a014c0fe37c30825d565d49bf23bb9ca212cec2442930fa1413201f6dd"

      def install
        bin.install "yubikey-agent"
      end
    end
  end

  conflicts_with "yubikey-agent", because: "you'll want to use the sandstorm forked version of yubikey-agent"

  def post_install
    (var/"run").mkpath
    (var/"log").mkpath
  end

  def caveats
    <<~EOS
      To use this SSH agent, add the config to ~/.ssh/config:

        Host *
          IdentityAgent #{var}/run/yubikey-agent.sock
    EOS
  end

  service do
    run [opt_bin/"yubikey-agent", "-l", var/"run/yubikey-agent.sock"]
    keep_alive true
    log_path var/"log/yubikey-agent.log"
    error_log_path var/"log/yubikey-agent.log"
  end

  test do
    socket = testpath/"yubikey-agent.sock"
    fork { exec bin/"yubikey-agent", "-l", socket }
    sleep 1
    assert_predicate socket, :exist?
  end
end
