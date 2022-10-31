# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class Synco < Formula
  desc "Sandstorm Synco"
  homepage "https://github.com/sandstorm/synco"
  version "0.1.8"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.8/synco_Darwin_arm64.tar.gz"
      sha256 "216fe2988ce9dce6cf1f57ae2d86ca98dfc26aa4c5e2d5b591800031b6f97eac"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.8/synco_Darwin_amd64.tar.gz"
      sha256 "84841383988082ab5836d606b22150082ea912458716dde9ed191529dd40b15d"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
  end

  on_linux do
    if Hardware::CPU.arm? && !Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.8/synco_Linux_armv6.tar.gz"
      sha256 "1cb09e1b6c5f5f545b2b916bf98f4ecb10c4ee89498aabf80978537fb88343ce"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.arm? && Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.8/synco_Linux_arm64.tar.gz"
      sha256 "51874b824ecec50e5ddfcf665e7a40ad7bf97ccb4ba3bab5ad1e34e6f624bfa3"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.8/synco_Linux_amd64.tar.gz"
      sha256 "ae75501e0f9c47af9981407b91a814b311871317b1ecc88e51018472a220d89d"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
  end
end
