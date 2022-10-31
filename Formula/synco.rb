# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class Synco < Formula
  desc "Sandstorm Synco"
  homepage "https://github.com/sandstorm/synco"
  version "0.1.7"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.7/synco_Darwin_arm64.tar.gz"
      sha256 "69637a7b3b20850d72cd4ded11b8308d4857229d7e44dc9200a390fb1b6533f2"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.7/synco_Darwin_amd64.tar.gz"
      sha256 "03e70e130577b6f3133e9beed42aae9dd82d7fc81101b95d8019d961da3b37bf"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
  end

  on_linux do
    if Hardware::CPU.arm? && !Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.7/synco_Linux_armv6.tar.gz"
      sha256 "b5d2cdc700802cfedef8b7c5839171deb192da75665e0fabd77055a100f783b6"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.arm? && Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.7/synco_Linux_arm64.tar.gz"
      sha256 "b0d01a95c671bb1b35570ca473dc8c2ca2d10906350691ee976c3ffa4dd8757b"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.1.7/synco_Linux_amd64.tar.gz"
      sha256 "3d11ab8fae3a86e2e5b8f30d99a951f82069094e7cf192037887616d2159f743"

      def install
        bin.write_exec_script libexec/"synco"
      end
    end
  end
end
