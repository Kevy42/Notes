#!/usr/bin/env bash

set -e -u -E -T -o pipefail

declare -i -r sshd_listen_port=42420
declare -i -r remote_listen_port=42069

function cleanup_on_exit() {
    trap - EXIT # Removing exit trap so cleanup_on_exit() doesn't run twice if the trap is triggered by some other signal (e.g CTRL-C sending an INT)

    # NOTE: all echo's appended with "|| true" as the may fail if HUP occures due to the stdout fd being closed
    echo || true # So "^C" doesn't interfere with below output
    echo "Exiting..."

    if jobs %1 &>/dev/null; then
        echo "killing temporary sshd instance..."

        # Is technically not needed as we're using job control to run the sshd proccess in the background, meaning it'll be killed upon the script exiting
        kill -9 %1 &>/dev/null # "%1" first job in job list. Sadly no way of suppressing the job control notification
        sleep 5                # needs some time to kill the background job
    fi

    if [[ "${openssh_server_installed:-}" == "true" ]]; then
        echo "Purging openssh-server..." || true

        if ! sudo apt-get purge openssh-server -qq --yes >/dev/null || ! sudo apt-get autopurge -qq --yes >/dev/null; then
            echo "Failed to purge openssh-server" || true
        fi
    fi

    exit 0
}

trap '' TSTP # Prevent suspension from terminal using CTRL+z
trap cleanup_on_exit INT
trap cleanup_on_exit QUIT
trap cleanup_on_exit HUP
trap cleanup_on_exit EXIT

echo "This script will:"
echo "1. Install openssh-server (if not already installed)"
echo "2. Start an sshd listener on loopback port $sshd_listen_port"
echo "3. Perform a reverse forward of said port up to a user specified remote"
echo "4. Purge (if installation was performed) and clean up openssh-server upon exit"
echo
echo "This will *automagically* allow the remote host to SSH back to this machine for a period of 24 hours (so long as the script is running), no further networking voodoo required!"

cat <<'EOF'

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@..*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@:   -@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@#  ###.+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@-.######-:@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%..:@@
@@@@@@@-+########.=@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@:****#:@@
@@@@@@@@:*#########+.@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@-+*###****:@@
@@@@@@@@@-*##########%.@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@=*#######**** :@@
@@@@@@@@@@-*############.*@@@@@@@@@@@@@@@@@@@@@@@%-=##########***#.@@@@
@@@@@@@@@@@*-##############%:.................-%#############****:@@@@@
@@@@@@@@@@@@@.*############################################****.@@@@@@@
@@@@@@@@@@@@@@@.#######################################*****#.#@@@@@@@@
@@@@@@@@@@@@@@@@*+#################################*******=.@@@@@@@@@@@
@@@@@@@@@@@@@@@@@%.##################################**.=.@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@.*###################################**.%@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@*###########################.#########*#%@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@:*#####.@@ ################.@@..#######**.@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@.######+.  #################   *#######**:%@@@@@@@@@@@@
@@@@@@@@@@@@@@@.*#######################################**.@@@@@@@@@@@@
@@@@@@@@@@@@@@@.*################.-#####################**:%@@@@@@@@@@@
@@@@@@@@@@@@@@#-===.#############################.-==.=##**.@@@@@@@@@@@
@@@@@@@@@@@@@@.====-+###########################:=====-##**:%@@@@@@@@@@
@@@@@@@@@@@@@@.====.############.++*+.###########=====.##***.@@@@@@@@@@
@@@@@@@@@@@@@@:*#:#############.+*****+###########..:.###***.@@@@@@@@@@
@@@@@@@@@@@@@@=*###############.*+****###################****:@@@@@@@@@
@@@@@@@@@@@@@@@.*################....-###################****.@@@@@@@@@
@@@@@@@@@@@@@@@@.*######################################*****#*@@@@@@@@
@@@@@@@@@@@@@@@@@.*#####################################******.@@@@@@@@
@@@@@@@@@@@@@@@@@-********###############################*****.@@@@@@@@
@@@@@@@@@@@@@@@@:**#######################################****.@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

EOF

echo "Neat, right?"
echo -e "\033[31mBecause stupid problems require stupid solutions...\033[0m"
echo

if [[ -r /etc/os-release ]]; then
    source /etc/os-release
else
    echo "Failed to identify Linux distribution. Damn, you must either be running something insanely custom or a really, really really fucked up system"
    exit 1
fi

if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
    read -r -p "Continue? y/n: " choice
else
    read -r -p "Script only supports Debian-based distributions, but may still work so long as APT (or openssh-server) and systemd are available. Continue? y/n: " choice
fi

if [[ "$choice" != "y" ]]; then
    exit 1
fi

if ! dpkg -s openssh-server &>/dev/null; then # Check if openssh-server is installed
    echo "openssh-server not found, installing..."

    if ! sudo apt-get update -qq --yes >/dev/null; then
        echo "Failed to update repositories"
        exit 1
    fi

    if ! sudo apt-get install openssh-server -qq --yes >/dev/null; then
        echo "Failed to install openssh-server"
        exit 1
    fi

    declare -r openssh_server_installed="true"

    # All we really need is the sshd binary, not the actual service. Disabling it as a security precatuion in case cleanup_on_exit() fails
    sudo timeout --kill-after=5 5 systemctl disable --quiet ssh.service # Cannot disable using "--now" (e.g stop the service) as sshd throws a "missing privilege separation directory" error when ran
elif ! systemctl is-active --quiet ssh.service; then
    echo "openssh-server already installed but service not active, aborting to avoid muching up potential custom config(s)"
    exit 1
fi

echo "Starting temporary sshd instance..."

# Check to make sure sshd starts correctly before comitting it to a background job as there's no (trivial) way of checking for errors in that state.
# sshd exit code is returned unless the timeout is triggered, which it should under normal circumstances given sshd simply blocks after having started correctly.
exit_code=$(
    sudo timeout --kill-after 60s 5s /usr/sbin/sshd -D -o ListenAddress=127.0.0.1 -p $sshd_listen_port &>/dev/null
    echo $?
)

if ((exit_code == 255)); then # Technically an umbrella code for various errors, but eh...
    echo "Failed to start temporary sshd instance, listen port in use?"
    exit 1
fi

if ((exit_code != 124)); then # The default timeout exceeded code
    echo "Failed to start temporary sshd instance"
    exit 1
fi

sudo timeout --kill-after 60s 24.5h /usr/sbin/sshd -D -o ListenAddress=127.0.0.1 -p $sshd_listen_port &>/dev/null & # 24h as a security precatuion in the case machine is left unattended

read -a ssh_args -r -p "Enter SSH remote (write the command like you normally would): "
declare -r -a ssh_args=("${ssh_args[@]:1}") # Remove first index ("ssh") to get arguments only

echo "starting reverse forward (ssh -R 127.0.0.1:$remote_listen_port:127.0.0.1:$sshd_listen_port). No further output (beyond any login prompts) expected. CTRL-C *once* to exit"
timeout \
    --foreground \
    --kill-after 60s 24h \
    ssh \
    -N \
    -o ConnectTimeout=10 \
    -R 127.0.0.1:$remote_listen_port:127.0.0.1:$sshd_listen_port \
    "${ssh_args[@]}"
