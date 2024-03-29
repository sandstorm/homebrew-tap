# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class SandstormDependencyAnalysis < Formula
  desc "Sandstorm Dependency Analysis"
  homepage "https://github.com/sandstorm/dependency-analysis"
  version "1.4.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/dependency-analysis/releases/download/v1.4.0/dependency-analysis_1.4.0_Darwin_arm64.tar.gz"
      sha256 "7d31a85bec808ff0dd1d7d3f02e9ea4ae44750b42f140c1d0f85e65e36ad7cf8"

      def install
        bin.install "sandstorm-dependency-analysis" => "sda"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/dependency-analysis/releases/download/v1.4.0/dependency-analysis_1.4.0_Darwin_x86_64.tar.gz"
      sha256 "7fe517f31ff36988154e14c64d1d3c6d63cc440adf451487219812a48bc0cd01"

      def install
        bin.install "sandstorm-dependency-analysis" => "sda"
      end
    end
  end

  on_linux do
    if Hardware::CPU.arm? && !Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/dependency-analysis/releases/download/v1.4.0/dependency-analysis_1.4.0_Linux_armv6.tar.gz"
      sha256 "d06d6fea2b9082560578853f035c646a060a982a8efcc89b27a19cd5cf85fed8"

      def install
        bin.install "sandstorm-dependency-analysis" => "sda"
      end
    end
    if Hardware::CPU.arm? && Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/dependency-analysis/releases/download/v1.4.0/dependency-analysis_1.4.0_Linux_arm64.tar.gz"
      sha256 "e73c801bdbf603bedac2feb98e1c86139e3263a0044c475ddfde9f876e2a08fd"

      def install
        bin.install "sandstorm-dependency-analysis" => "sda"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/dependency-analysis/releases/download/v1.4.0/dependency-analysis_1.4.0_Linux_x86_64.tar.gz"
      sha256 "9214ad47fb0a98c38e87c11ace960b026f1848ca70185a5f5fa7895f3d796d07"

      def install
        bin.install "sandstorm-dependency-analysis" => "sda"
      end
    end
  end
end
