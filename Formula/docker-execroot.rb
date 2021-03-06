# This file was generated by GoReleaser. DO NOT EDIT.
class DockerExecroot < Formula
  desc "Sandstorm Docker Debug Tools"
  homepage "https://github.com/sandstorm/docker-execroot"
  version "1.0.1"
  bottle :unneeded

  if OS.mac?
    url "https://github.com/sandstorm/docker-execroot/releases/download/1.0.1/docker-execroot_1.0.1_Darwin_x86_64.tar.gz"
    sha256 "ef9a1132b9f0dda22de57fd76f0730f9e7625040784edf6a0a6e16152af4f45e"
  end

  def caveats
    caveats =
      <<~EOS

        !!! Please run the following commands to finish installing the docker-execroot plugin:

        ---------------------------------------------------------------------------------
        mkdir -p ~/.docker/cli-plugins
        rm -f ~/.docker/cli-plugins/docker-execroot
        ln -s #{pkgshare}/docker-execroot ~/.docker/cli-plugins/docker-execroot

        rm -f ~/.docker/cli-plugins/docker-vscode
        ln -s #{pkgshare}/docker-execroot ~/.docker/cli-plugins/docker-vscode
        ---------------------------------------------------------------------------------
      EOS

    caveats
  end

  def install
    pkgshare.install Dir["*"]
  end
end
