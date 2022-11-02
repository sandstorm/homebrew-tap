# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class Synco < Formula
  desc "Sandstorm Synco"
  homepage "https://github.com/sandstorm/synco"
  version "0.4.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.0/synco_Darwin_arm64.tar.gz"
      sha256 "fa936eaa56231a4f18116491d5aa58d4fc9bdc6497d9c59121d9df1024a2cb73"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.0/synco_Darwin_x86_64.tar.gz"
      sha256 "52d34d70e2ae936b798f1ac50cd94f594d03028ad36e7726949b90185732d179"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
  end

  on_linux do
    if Hardware::CPU.arm? && !Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.0/synco_Linux_armv6.tar.gz"
      sha256 "e85d8cc110617673a76cc3bde1d95528c99a3e4a0bc8fc85ac26c9609a5b8761"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.arm? && Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.0/synco_Linux_arm64.tar.gz"
      sha256 "4ba396ec31e366104422cba7bf3bc621ce6c83fd9836951086baa2102b99a351"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.0/synco_Linux_x86_64.tar.gz"
      sha256 "d297d17605841687d58151ea5a57eb0256e81c87ceb561b82736e3b2b2ee51f0"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
  end
end
