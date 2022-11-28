# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class DevScriptRunner < Formula
  desc "Sandstorm Dev Script Runner"
  homepage "https://github.com/sandstorm/dev-script-runner"
  version "0.1.0"
  depends_on :macos

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/Sandstorm.DevScriptRunner/releases/download/v0.1.0/Sandstorm.DevScriptRunner_0.1.0_Darwin_arm64.tar.gz"
      sha256 "2408c017d9d136199493940fca0894f6f975709200e06ba600b2f0c06e6e9e1c"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"dev-script-runner"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/Sandstorm.DevScriptRunner/releases/download/v0.1.0/Sandstorm.DevScriptRunner_0.1.0_Darwin_x86_64.tar.gz"
      sha256 "8ea6afc5317b20cac5a617220ede9b09fb5d22b583ef1c9b66a6426dde961719"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"dev-script-runner"
      end
    end
  end
end
