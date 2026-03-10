#!/bin/bash

# --- Configuration ---
LINK_PATH="$HOME/stacks"
TARGET_DIR="/srv/stacks"
GROUP_NAME="docker"

# --- Functions ---

check_docker_group() {
    echo "--- Checking Docker Group Configuration ---"

    # 1. Check if the group exists
    if ! getent group "$GROUP_NAME" > /dev/null; then
        echo "CRITICAL ERROR: The group '$GROUP_NAME' does not exist."
        echo "Please install Docker before running this script."
        exit 1
    fi

    # 2. Check if user is in the group
    if ! groups "$USER" | grep -q "\b$GROUP_NAME\b"; then
        echo "User '$USER' is NOT in the '$GROUP_NAME' group."
        read -p "   Add user '$USER' to '$GROUP_NAME' group? [y/N]: " group_resp

        if [[ "$group_resp" =~ ^[yY] ]]; then
            echo "   Adding user to group..."
            sudo usermod -aG "$GROUP_NAME" "$USER"
            echo "   User added. NOTE: You may need to re-login for this to take full effect."
        else
            echo "   Skipping group addition. You may face permission errors."
        fi
    else
        echo "Success: '$USER' is already in '$GROUP_NAME'."
    fi
}

setup_paths() {
    echo -e "\n--- Checking Path & Symlinks ---"
    local proceed=false

    # 1. Clean Install Check
    # (! -e checks existence, ! -L checks if it's a broken symlink)
    if [ ! -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
        proceed=true

    # 2. Conflict Check
    else
        local current_target
        current_target=$(readlink "$LINK_PATH")

        if [ "$current_target" != "$TARGET_DIR" ]; then
            echo "CONFLICT: $LINK_PATH exists but does not point to $TARGET_DIR"

            if [ -d "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
                echo "   Status: It is currently a standard directory."
            else
                echo "   Status: It points to '$current_target'."
            fi

            read -p "   Update symlink? (WARNING: This deletes the existing $LINK_PATH) [y/N]: " response
            if [[ "$response" =~ ^[yY] ]]; then
                echo "   Removing old path..."
                rm -rf "$LINK_PATH"
                proceed=true
            else
                echo "   Skipping update."
            fi
        else
            echo "Success: $LINK_PATH is correctly linked."
        fi
    fi

    # 3. Execution
    if [ "$proceed" = true ]; then
        # Check/Create /srv target
        if [ ! -d "$TARGET_DIR" ]; then
            echo "   Creating $TARGET_DIR..."
            sudo install -d -m 770 -o "$USER" -g "$GROUP_NAME" "$TARGET_DIR"
        fi

        # Create symlink
        ln -s "$TARGET_DIR" "$LINK_PATH"
        echo "   Symlink created: $LINK_PATH -> $TARGET_DIR"
    fi
}

check_docker_service() {
    echo -e "\n--- Checking Docker Service Status ---"

    # Check if systemctl is available (systemd check)
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet docker; then
            echo "Success: Docker service is running."
        else
            echo "WARNING: Docker service is NOT running."
            read -p "   Would you like to start Docker now? [y/N]: " svc_resp
            if [[ "$svc_resp" =~ ^[yY] ]]; then
                sudo systemctl start docker
                echo "   Attempting to start Docker..."

                # Double check
                if systemctl is-active --quiet docker; then
                    echo "   Docker started successfully."
                else
                    echo "   Failed to start Docker. Please check logs."
                fi
            fi
        fi
    else
        echo "Skipping service check (systemctl not found)."
    fi
}

# --- Main Execution ---
check_docker_group
setup_paths
check_docker_service

echo -e "\nSetup Complete."
