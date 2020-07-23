# Forked yubikey-agent from https://github.com/FiloSottile/yubikey-agent/blob/47bc9321572e2a15a18ed8060a4537f15339ef4c/HomebrewFormula/yubikey-agent.rb
# WHAT HAS CHANGED?
# - using https://github.com/skurfuerst/yubikey-agent/releases/tag/custom-password-caching binary

class YubikeyAgent < Formula
    desc "Seamless ssh-agent for YubiKeys"
    homepage "https://filippo.io/yubikey-agent"
    url "https://github.com/skurfuerst/yubikey-agent/releases/download/custom-password-caching/yubikey-agent-osx.zip"
    sha256 "8c88f9bf0ff8fabe8fe2d4a61159aba46f425c297bfaeb205882038d8760afb0"
    version "1.0.0-forked"
  
    depends_on "pinentry-mac"
  
    def install
      bin.install "yubikey-agent"
    end
  
    def post_install
      (var/"run").mkpath
      (var/"log").mkpath
    end
  
    def plist
      <<~EOS
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{plist_name}</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>/usr/bin:/bin:/usr/sbin:/sbin:#{Formula["pinentry-mac"].opt_bin}</string>          </dict>
          <key>ProgramArguments</key>
          <array>
            <string>#{opt_bin}/yubikey-agent</string>
            <string>-l</string>
            <string>#{var}/run/yubikey-agent.sock</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key>
          <string>Background</string>
          <key>StandardErrorPath</key>
          <string>#{var}/log/yubikey-agent.log</string>
          <key>StandardOutPath</key>
          <string>#{var}/log/yubikey-agent.log</string>
        </dict>
        </plist>
      EOS
    end
  
    def caveats
      <<~EOS
        To set up a new YubiKey, run this command:
          yubikey-agent -setup
  
        To use this SSH agent, set this variable in your ~/.zshrc and/or ~/.bashrc:
          export SSH_AUTH_SOCK="#{var}/run/yubikey-agent.sock"
      EOS
    end
  end
  