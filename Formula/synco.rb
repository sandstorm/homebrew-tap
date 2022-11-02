# typed: false
# frozen_string_literal: true

# This file was generated by GoReleaser. DO NOT EDIT.
class Synco < Formula
  desc "Sandstorm Synco"
  homepage "https://github.com/sandstorm/synco"
  version "0.4.3"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.3/synco_Darwin_arm64.tar.gz"
      sha256 "6b9936fc806e618d85637d43d98e027a46e954b73acf5b3b2e592bbcc8a616d5"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.3/synco_Darwin_x86_64.tar.gz"
      sha256 "fcf0b86135bc1080cb11fa380fe532eee3b3d90fc2596d6ba965cd40325f1102"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
  end

  on_linux do
    if Hardware::CPU.arm? && !Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.3/synco_Linux_armv6.tar.gz"
      sha256 "5fa70c2bd495475ccce5a66b1dea4d95f96d04e8b53dabde0a97507db73ff53e"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.arm? && Hardware::CPU.is_64_bit?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.3/synco_Linux_arm64.tar.gz"
      sha256 "07f7de10df364dba50c2730c7427eaa026c37bc972f5d36efc1e3a1722be0652"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
    if Hardware::CPU.intel?
      url "https://github.com/sandstorm/synco/releases/download/v0.4.3/synco_Linux_x86_64.tar.gz"
      sha256 "cd4f7b8447866679cdc37aa0dcbe3de7020ea4bdc232dcee9665b6b91e2a5970"

      def install
        libexec.install Dir["*"]
        bin.write_exec_script libexec/"synco"
      end
    end
  end
end
