#!/bin/bash -e

# KDB-X Installation Script

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
BOLD=$(tput bold)
NC=$(tput sgr0)

DTM=$(date +%Y%m%d_%H%M%S)
INSTALL_DIR="$HOME/.kx"
SCRIPT_DIR="$(dirname $0)"
TEMP_DIR=""

ROLLBACK_REQUIRED=false
ARCHIVE_REQUIRED=false
INSTALL_DIR_CREATED=false
ARCHIVE_FILE=""
CONFIG_FILE_MODIFIED=""

B64_LIC=""
K4B64_LIC=""
OFFLINE_MODE=false
ACCEPT_DEFAULTS=false
QTEL_ENABLED=""

bold() {
    printf "%s%s%s" "$BOLD" "$1" "$NC"
}

TELEMETRY_PROMPT=$(cat <<'EOF'
You will be given the option to opt in to usage telemetry when you install KDB-X Community Edition or a KX product that includes embedded KDB-X functionality. If you choose to opt in, we will collect data relating to the operation and usage of KDB-X technology, including performance metrics, configuration and settings, diagnostics relating to the operation of KDB-X technology, and information about how features are used.  

This may include identifiers (such as user ID, IP address, and license information), which can be used to associate telemetry data with a user, device, or account.  

We use this data to operate, support, and improve KDB-X technology, and for analytics purposes, including understanding usage patterns, customer engagement, and potential interest in our products and services. These activities are used for internal analysis and does not result in automated decisions that produce legal or similarly significant effects.  

You can withdraw your consent and disable telemetry at any time by following the instructions in our software Documentation: https://code.kx.com/kdb-x/releases/telemetry.html

For more information on the telemetry data we collect and how it is used, please refer to the Telemetry Data Statement (https://kx.com/legal/kdb-x-telemetry-data-statement-07-26), and for details on how we handle personal data more generally, please refer to our Privacy Policy: https://kx.com/privacy-policy/. 
EOF
)

TELEMETRY_NO_PROMPT=$(cat <<EOF
$(bold "Telemetry Data Statement")

KX collects telemetry data relating to the operation and usage of KDB-X technology, including KDB-X Community Edition and KDB-X functionality embedded within other KX products, including performance metrics, configuration and settings, and diagnostics relating to the operation of KDB-X technology. This telemetry may include identifiers (such as IP address, User ID, and license information), which can be used to associate telemetry data with a user, device, or account. 

While telemetry is enabled by default for certain users in the United States, users in other regions may choose to enable telemetry. Where telemetry is enabled, the data collection and use described in this statement applies.  

The data collected falls within categories such as identifiers, commercial information (such as license details), and internet or other electronic network activity information (such as usage data). For purposes of applicable U.S. state privacy laws, including the California Consumer Privacy Act, as amended by the California Privacy Rights Act (“CCPA”), this information constitutes “personal information” where it identifies, relates to, or could reasonably be linked with an individual, household or device. 


$(bold "Telemetry Data in Scope")

Metric                      Description                                  Purpose of Collection
------                      -----------                                  ---------------------
Date and Time               Reports time and date when telemetry         System Performance and
                            is collected                                 Resource Context

External IP                 IP address associated with the device        Identification

Name of host server         Identifier for the server instance           Identification

Operating System            Type and version of OS user is running       Feature Usage and
                                                                         Insights

Process IDs                 Specific IDs for active kdb processes        Feature Usage and
                                                                         Insights

User ID                     Name of logged on user                       Identification

Version Information         Active product release and date              System Performance and
                                                                         Resource Context

Threads                     Number of threads spawned by the q process   Feature Usage and
                                                                         Insights

Port                        Port information for active q processes      Feature Usage and
                                                                         Insights

License Details             Customer details including unique            Identification
                            license number

Cores                       Number of CPU cores in use                   System Performance and
                                                                         Resource Context

CPU Utilization             Process-specific CPU Usage                   System Performance and
                                                                         Resource Context

KDB-X Module Invocations    Data collected on active modules             Feature Usage and Insights

Dataset Identifier          Identifier of the predefined dataset         Feature Usage and Insights
                            accessed through KDB-X functionality         

For the purpose of the above table, the following definitions apply: 

- Identification: Used to identify and distinguish users, devices and installations in order to provide and manage access to KDB-X technology, including licensing, authentication, and ensuring that usage can be attributed to the correct user or environment.   

- Feature Usage and Insights: Used to understand how features and functionality of KDB-X technology are used in practice, including which features are accessed and how they are used, to improve existing functionality and inform the development of new features. 

- System Performance and Resource Context: Used to understand the technical environment and performance of KDB-X technology, including system configuration, resource utilisation, and diagnostics related to issues encountered, in order to support product optimisation and ensure KDB-X technology operates effectively across different technical environments. 

In addition to the purposes described above, KX may use telemetry data, including personal information, for broader analytics and business purposes. This includes analysing how KDB-X technology is used across users and environments, generating aggregated insights, and developing internal models or scores to better understand usage patterns, customer engagement, and potential interest in our products and services. These activities do not result in automated decisions that produce legal or similarly significant effects, but may inform how we communicate with you, including providing product updates, service-related communications, and, where permitted by applicable law, marketing or promotional communications. 

$(bold "Sharing of Telemetry Data")

KX may share data, including personal information, with third parties service providers that support the operation, analysis, and improvement of KDB-X technology. These third-party service providers act on our behalf and are subject to contractual and other safeguards governing their use of the data.  

These categories of recipients include: 

- Cloud and infrastructure providers, who host and store telemetry data and support system operations. 
- Analytics and data processing providers, who help us collect, process, and analyse telemetry data to understand product usage and performance.  
- Customer relationship and engagement platforms, which may be used to manage account information, analyse usage patterns, and support customer engagement activities.  
- Reporting and business intelligence tools, which are used to generate aggregated insights and internal reporting dashboards.   

Where telemetry data is shared, it is used solely to support the purposes described in this statement.  

For the avoidance of doubt, KX does not sell personal information or process personal information for cross-context behavioural advertising purposes.  

$(bold "Retention")

We retain telemetry data for no longer than is necessary to fulfil the purposes described above. In general, identifiable telemetry data is retained for a limited period (typically up to ninety (90) days), after which it is deleted or no longer retained in an identifiable form.  

In some cases, telemetry data may be aggregated or otherwise transformed into derived data (such as usage scores or similar analytical outputs). Where this occurs, the derived data may be retained for a longer period to support ongoing analytics, product improvement, and customer engagement activities, and is maintained independently of the underlying raw telemetry data.  

$(bold "Your Rights and Choices")

Depending on your U.S. state of residence, you may have certain rights in relation to your personal information, including the right to request access to, correction of, deletion of, or a copy of your personal information, and to opt out of certain processing activities, including the sale of personal information, cross-context behavioural advertising (also known as targeted advertising), or profiling in furtherance of decisions that produce legal or similarly significant effects.  

You may also choose to limit certain data collection and use, including by disabling telemetry and opting out of marketing communications using the unsubscribe mechanisms provided.  

To exercise your rights or learn more about how we use your personal information, please refer to our Privacy Policy (https://kx.com/privacy-policy/).  

$(bold "Opt-Out")

Telemetry is enabled to collect usage and system data as described above. You may turn off telemetry at any time by following the instructions at: https://code.kx.com/kdb-x/releases/telemetry.html.  

Please note that telemetry data may have been collected and transmitted prior to the point at which you disable the setting. 

You may also opt out of receiving marketing communications from us at any time by using the unsubscribe mechanism included in such communications or by contacting us as described in our Privacy Policy.  

EOF
)

check_args() {
    for arg in "$@"; do
        if [ "$B64_LIC" = "NEXT" ]; then
            B64_LIC="$arg"
            continue
        fi
        if [ "$K4B64_LIC" = "NEXT" ]; then
            K4B64_LIC="$arg"
            continue
        fi
        case $arg in
        --offline)
            OFFLINE_MODE=true
            ;;
        --b64lic)
            B64_LIC="NEXT"
            ;;
        --k4b64lic)
            K4B64_LIC="NEXT"
            ;;
        -y|--non-interactive)
            ACCEPT_DEFAULTS=true
            ;;
        *)
            print_error "Unknown argument: $arg"
            print_info "Usage: $0 [--offline] [--b64lic BASE64_LIC] [-y|--non-interactive]"
            exit 1
            ;;
        esac
    done

    if [ "$B64_LIC" = "NEXT" ]; then
        print_error "Missing value for --b64lic argument"
        print_info "Usage: $0 --b64lic BASE64_LIC"
        exit 1
    fi

    if [ "$K4B64_LIC" = "NEXT" ]; then
        print_error "Missing value for --k4b64lic argument"
        print_info "Usage: $0 --k4b64lic K4BASE64_LIC"
        exit 1
    fi

    if [ "$ACCEPT_DEFAULTS" = true ] && [ -z "$B64_LIC" ] && [ -z "$K4B64_LIC" ]; then
        print_error "License is required when using -y/--non-interactive mode"
        print_info "Usage: $0 -y [--b64lic BASE64_LIC|--k4b64lic BASE64_LIC]"
        exit 1
    fi

    if [ -n "$B64_LIC" ] && [ -n "$K4B64_LIC" ]; then
        print_error "Only one of [--b64lic, --k4b64lic] is allowed"
        print_info "Usage: $0 -y [--b64lic BASE64_LIC|--k4b64lic BASE64_LIC]"
        exit 1
    fi
}

print_header()  { printf "\n-------- %s --------\n" "$1"; }
print_success() { printf "%s%sSuccess: %s%s%s%s\n" "$BOLD" "$GREEN" "$NC" "$GREEN" "$1" "$NC"; }
print_blue()    { printf "%s%s%s\n" "$BLUE" "$1" "$NC"; }
print_green()   { printf "%s%s%s\n" "$GREEN" "$1" "$NC"; }
print_warning() { printf "%sWarning: %s%s\n" "$BOLD" "$NC" "$1"; }
print_error()   { printf "%s%sError: %s%s%s%s\n" "$BOLD" "$RED" "$NC" "$RED" "$1" "$NC"; }
print_info()    { printf "%s\n" "$1"; }

show_menu() {
    local options=("$@")

    if [ "$ACCEPT_DEFAULTS" = true ]; then
        print_info "Auto-selecting: ${options[0]}"
        return 0
    fi

    while true; do
        echo
        print_info "Options:"
        for i in "${!options[@]}"; do
            print_info "  $((i+1)). ${options[$i]}"
        done
        echo
        read -p "${BLUE}Please select an option [1-${#options[@]}]: " MENU_CHOICE
        printf $NC

        if [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] && [ "$MENU_CHOICE" -ge 1 ] && [ "$MENU_CHOICE" -le "${#options[@]}" ]; then
            return $((MENU_CHOICE-1))
        else
            echo
            print_error "Invalid option"
        fi
    done
}

perform_rollback() {
    print_header "Installation failed - Rolling back changes"

    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        print_info "  Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi

    if [ "$INSTALL_DIR_CREATED" = true ] && [ -d "$INSTALL_DIR" ]; then
        print_info "  Removing installation directory: $INSTALL_DIR"
        rmdir "$INSTALL_DIR" 2>/dev/null || true
    fi

    if [ -n "$ARCHIVE_FILE" ] && [ -f "$ARCHIVE_FILE" ]; then
        print_info "  Restoring previous installation from archive"
        tar -xz -C $(dirname "$INSTALL_DIR") -f "$ARCHIVE_FILE" || {
            print_warning "Failed to restore from archive, but archive file preserved: $ARCHIVE_FILE"
        }
    fi

    if [ -n "$CONFIG_FILE_MODIFIED" ] && [ -f "$CONFIG_FILE_MODIFIED.kdb_backup.$DTM" ]; then
        print_info "  Restoring configuration file: $CONFIG_FILE_MODIFIED"
        mv "$CONFIG_FILE_MODIFIED.kdb_backup.$DTM" "$CONFIG_FILE_MODIFIED" 2>/dev/null || true
    fi

    print_success "Rollback completed - System returned to previous state"

    exit 1
}

setup_error_trap() {
    trap 'handle_error $?' ERR
    trap cleanup EXIT
}

handle_error() {
    local exit_code=$1

    if [ $exit_code -ne 0 ] && [ "$ROLLBACK_REQUIRED" = true ]; then
        print_error "Error detected during installation (code: $exit_code)"
        perform_rollback
    fi
}

cleanup() {
    if [ $? -eq 0 ]; then
        if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
            rm -rf "$TEMP_DIR" 2>/dev/null || true
        fi
        if [ -n "$CONFIG_FILE_MODIFIED" ] && [ -f "$CONFIG_FILE_MODIFIED.kdb_backup.$DTM" ]; then
            rm "$CONFIG_FILE_MODIFIED.kdb_backup.$DTM" 2>/dev/null || true
        fi
    fi
}

check_prerequisites() {
    MISSING_PREREQS=()

    if [ "$OFFLINE_MODE" = false ] && ! command -v curl &> /dev/null; then
        MISSING_PREREQS+=("curl")
    fi

    if ! command -v unzip &> /dev/null; then
        MISSING_PREREQS+=("unzip")
    fi

    if [ ${#MISSING_PREREQS[@]} -gt 0 ]; then
        print_error "Missing prerequisites: ${MISSING_PREREQS[*]}"
        print_info "Please install the required packages and try again"
        exit 1
    fi
}

download_file() {
    local url="$1"
    local output_file="$2"

    if [ -t 1 ]; then
        curl --fail --progress-bar -Lo "$output_file" "$url"
    else
        curl --fail -Lo "$output_file" "$url"
    fi

    return $?
}


check_if_kdb_q() {
    local q_path="$1"

    local result=$(echo "'\`err" | "$q_path" 2>&1 | head -n 1 || echo "")

    if [[ "$result" =~ ^\'[0-9]{4}\.[0-9]{2}\.[0-9]{2}T ]]; then
        return 0  # This is kdb
    else
        return 1  # This is not kdb
    fi
}

check_existing_installation() {
    EXISTING_ISSUES=()

    QCMD=$(command -v q 2>/dev/null) || QCMD=""
    if [ -n "$QCMD" ]; then
        if check_if_kdb_q "$QCMD"; then
            EXISTING_ISSUES+=("Existing q command found: \"$QCMD\"")
        else
            print_info "Found 'q' command at $QCMD but it's not KX (possibly Amazon Q or another tool)"
        fi
    fi

    for var in QHOME QLIC QINIT; do
        if [ -n "${!var}" ]; then
            EXISTING_ISSUES+=("Existing \$$var envvar found: \"${!var}\"")
            print_warning "Unsetting existing $var variable for this installation"
            unset "$var"
        fi
    done

}

set_install_dir() {
    print_header "Setting install location"
    show_menu "Use default location ($INSTALL_DIR)" "Provide custom location"
    case $? in
        0) check_install_dir ;;
        1) set_custom_install_location ;;
    esac
}

check_install_dir() {
    if [ -n "$INSTALL_DIR" ]; then
        print_info "Checking installation location: $INSTALL_DIR"
    fi
    if [ -z "$INSTALL_DIR" ]; then
        print_warning "No installation location provided"
        if [ "$ACCEPT_DEFAULTS" = true ]; then
            print_error "Cannot proceed in non-interactive mode: no installation location provided"
            exit 1
        fi
        show_menu "Provide an installation location" "Abort installation"
        case $? in
            0) set_custom_install_location ;;
            1) print_info "Installation aborted by user"; exit 0 ;;
        esac
    elif [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
        print_warning "File found at installation target: $INSTALL_DIR"
        if [ "$ACCEPT_DEFAULTS" = true ]; then
            print_error "Cannot proceed in non-interactive mode: file exists at installation location"
            print_info "Please remove the file and try again: $INSTALL_DIR"
            exit 1
        fi
        show_menu "Install to a different location" "Abort installation (you can move/delete file and try again)"
        case $? in
            0) set_custom_install_location ;;
            1) print_info "Installation aborted by user"; exit 0 ;;
        esac
    elif [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        print_warning "Target installation directory exists and is not empty: $INSTALL_DIR"
        if [ "$ACCEPT_DEFAULTS" = true ]; then
            print_info "Auto-archiving existing directory and continuing with installation"
            ARCHIVE_REQUIRED=true
        else
            show_menu "Archive existing directory and continue with installation" "Install to a different location" "Abort installation"
            case $? in
                0) print_info "Will install to: $INSTALL_DIR (existing directory will be archived)"; ARCHIVE_REQUIRED=true ;;
                1) set_custom_install_location ;;
                2) print_info "Installation aborted by user"; exit 0 ;;
            esac
        fi
    elif [ ! -e "$INSTALL_DIR" ]; then
        if [ -d $(dirname "$INSTALL_DIR") ] && [ -w $(dirname "$INSTALL_DIR") ]; then
            print_green "Will install to: $INSTALL_DIR"
        else
            print_warning "Cannot create directory: $INSTALL_DIR"
            if [ "$ACCEPT_DEFAULTS" = true ]; then
                print_error "Cannot proceed in non-interactive mode: insufficient permissions to create directory"
                print_info "Please check permissions for: $(dirname "$INSTALL_DIR")"
                exit 1
            fi
            show_menu "Install to a different location" "Abort installation (you can check/change permissions and try again)"
            case $? in
                0) set_custom_install_location ;;
                1) print_info "Installation aborted by user"; exit 0 ;;
            esac
        fi
    else # empty directory
        if [ -w "$INSTALL_DIR" ]; then
            print_green "Will install to: $INSTALL_DIR"
        else
            print_warning "Cannot write to directory: $INSTALL_DIR"
            if [ "$ACCEPT_DEFAULTS" = true ]; then
                print_error "Cannot proceed in non-interactive mode: insufficient permissions to write to directory"
                print_info "Please check permissions for: $INSTALL_DIR"
                exit 1
            fi
            show_menu "Install to a different location" "Abort installation (you can check/change permissions and try again)"
            case $? in
                0) set_custom_install_location ;;
                1) print_info "Installation aborted by user"; exit 0 ;;
            esac
        fi
    fi
}

archive_existing_installation() {
    if [ ! -d "$INSTALL_DIR" ]; then
        print_info "No directory to archive at $INSTALL_DIR"
        return 0
    fi

    ARCHIVE_FILE="$HOME/kdb_backup.$DTM.tgz"
    print_info "Archiving existing installation to $ARCHIVE_FILE"
    tar -cz -C $(dirname "$INSTALL_DIR") -f "$ARCHIVE_FILE" $(basename "$INSTALL_DIR") || {
        print_error "Failed to create archive - you may want to manually backup your existing installation"
        ARCHIVE_FILE=""
        return 1
    }
    print_green "Existing installation archived to $ARCHIVE_FILE"

    rm -rf "$INSTALL_DIR" 2>/dev/null || {
        print_error "Failed to remove existing directory: $INSTALL_dir"
        print_error "Please manually remove it and try again"
        return 1
    }
    print_green "Old installation directory removed"
}

set_custom_install_location() {
    read -p "${BLUE}Please specify a new installation directory: " INSTALL_DIR
    printf $NC
    echo
    if [ -n "$INSTALL_DIR" ]; then
        INSTALL_DIR="${INSTALL_DIR/#~\//$HOME/}"
        case "$INSTALL_DIR" in
            /*) : ;;
            *) INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
        esac
    fi
    check_install_dir
}

check_platform() {
    print_header "Detecting platform"
    OS=$(uname -s)
    ARCH=$(uname -m)
    PREFIX=

    if [ "$OS" = "Linux" ]; then
        if [ "$ARCH" = "x86_64" -o "$ARCH" = "amd64" ]; then
            PREFIX="l64"
        elif [ "$ARCH" = "aarch64" -o "$ARCH" = "arm64" ]; then
            PREFIX="l64arm"
        fi
    elif [ "$OS" = "Darwin" ]; then
        PREFIX="m64"
    fi

    if [ -z "$PREFIX" ]; then
        print_error "Unsupported OS+Architecture combination: $OS+$ARCH"
        exit 1
    fi

    print_info "Detected system: $OS ($ARCH)"
    print_info "Using platform prefix: $PREFIX"
    SHELL_TYPE=$(basename "$SHELL")
}

extract_component() {
    local zip_file="$1"
    local target_dir="$2"
    local component_name="$3"

    local temp_extract="$TEMP_DIR/${component_name}_extract"
    printf "Extracting $component_name "

    local expected_size
    expected_size=$(unzip -l "$zip_file" | tail -1 | awk '{print $1}')

    unzip -q -o "$zip_file" -d "$temp_extract" &
    local unzip_pid=$!

    local dots_shown=0
    while kill -0 $unzip_pid 2>/dev/null; do
        local current_size=0
        if [ -d "$temp_extract" ]; then
            current_size=$(du -s "$temp_extract" 2>/dev/null | awk '{print $1 * 1024}')
        fi

        local percentage=0
        if [ "$expected_size" -gt 0 ]; then
            percentage=$(( (current_size * 100) / expected_size ))
        fi

        local dots_to_show=$(( percentage / 10 ))
        while [ $dots_shown -lt $dots_to_show ] && [ $dots_shown -lt 10 ]; do
            printf "."
            dots_shown=$((dots_shown + 1))
        done

        sleep 0.2
    done

    while [ $dots_shown -lt 10 ]; do
        printf "."
        dots_shown=$((dots_shown + 1))
    done

    printf "\n"

    if ! wait $unzip_pid; then
        print_warning "Failed to extract $component_name. Continuing without $component_name"
        return 1
    fi

    local source_dir="$temp_extract"
    local extracted_dirs=("$temp_extract"/*)

    [ ${#extracted_dirs[@]} -eq 1 ] && [ -d "${extracted_dirs[0]}" ] && source_dir="${extracted_dirs[0]}"

    mkdir -p "$target_dir" && mv "$source_dir"/* "$target_dir/" 2>/dev/null || {
        print_warning "Failed to install $component_name. Continuing without $component_name"
        rm -rf "$temp_extract"
        return 1
    }

    rm -rf "$temp_extract"
    return 0
}

get_offline_component() {
    local componentName="$1"  # "kdb", "ai", "kurl", "objstor", "pq", "dashboards", or "rest"
    local expected_filename=""
    local script_filename=""
    local target_dir=""
    local actual_path=""
    local actual_name=""
    local attempt=""

    if [ "$componentName" = "ai" ]; then
        print_header "AI libraries - Offline installation"
        expected_filename="$PREFIX-ai.zip"
    elif [ "$componentName" = "kurl" ]; then
        print_header "kurl module - Offline installation"
        expected_filename="$PREFIX-kurl.zip"
    elif [ "$componentName" = "objstor" ]; then
        print_header "objstor module - Offline installation"
        expected_filename="$PREFIX-objstor.zip"
    elif [ "$componentName" = "pq" ]; then
        print_header "Parquet module - Offline installation"
        expected_filename="pq.zip"
    elif [ "$componentName" = "rest" ]; then
        print_header "REST server module - Offline installation"
        expected_filename="rest-server.zip"
    elif [ "$componentName" = "sql" ]; then
        print_header "SQL module - Offline installation"
        expected_filename="$PREFIX-sql.zip"        
    elif [ "$componentName" = "dashboards" ]; then
        print_header "Dashboards - Offline installation"
        expected_filename="KXDashboards.zip"
    else
        print_header "KDB-X - Offline installation"
        expected_filename="$PREFIX.zip"
    fi

    script_filename="$SCRIPT_DIR/$expected_filename"

    while true; do
        if [ -z "$attempt" ]; then
            attempt=1
        else
            if [ "$ACCEPT_DEFAULTS" = true ]; then
                if [ "$componentName" = "ai" ] || [ "$componentName" = "kurl" ] || [ "$componentName" = "objstor" ] || [ "$componentName" = "pq" ] || [ "$componentName" = "rest" ] || [ "$componentName" = "dashboards" ]; then
                    print_warning "File not found, skipping optional component: $expected_filename"
                    COMPONENT_PATH=""
                    break
                else
                    print_error "Cannot proceed in non-interactive mode: required file not found: $expected_filename"
                    print_info "Please ensure the file is in: $SCRIPT_DIR"
                    exit 1
                fi
            fi
            if [ "$componentName" = "ai" ] || [ "$componentName" = "kurl" ] || [ "$componentName" = "objstor" ] || [ "$componentName" = "pq" ] || [ "$componentName" = "rest" ] || [ "$componentName" = "dashboards" ]; then
                show_menu "Try again" "Skip"
            else
                show_menu "Try again" "Abort installation"
            fi
            case $? in
                0) ;;
                1) COMPONENT_PATH=""; break ;;
            esac
        fi
        if [ -f "$script_filename" ]; then
            print_green "File detected: $script_filename."
            COMPONENT_PATH="$script_filename"
            break
        else
            read -p       "${BLUE}Enter path to $expected_filename: " actual_path
            printf $NC
        fi

        actual_path="$(echo "$actual_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        actual_path="${actual_path/#~\//$HOME/}"

        if [ -z "$actual_path" ]; then
            print_error "No path provided"
            continue
        fi

        if [ -d "$actual_path" ]; then

            target_dir="$actual_path"
            COMPONENT_PATH="$target_dir/$expected_filename"

            if [ ! -f "$COMPONENT_PATH" ]; then
                print_error "File $expected_filename not found in directory: $target_dir"
                continue
            fi
            break

        elif [ -f "$actual_path" ]; then
            COMPONENT_PATH="$actual_path"
            actual_name="$(basename "$COMPONENT_PATH")"

            if [ "$actual_name" != "$expected_filename" ]; then
                print_error "Filename mismatch: expected $expected_filename, got $actual_name"
                continue
            fi
            break

        else
            print_error "Invalid path: $actual_path"
            print_info "Path does not exist or is not accessible"
            continue
        fi

    done

    if [ -n "$COMPONENT_PATH" ]; then
        print_green "Using file: $COMPONENT_PATH"

        if [ "$(uname -s)" = "Darwin" ]; then
            print_info "Clearing extended attributes for: $COMPONENT_PATH"
            xattr -c "$COMPONENT_PATH"
        fi
    fi
}

download_kdb() {
    if [ "$OFFLINE_MODE" = true ]; then
        get_offline_component "kdb"
        if [ -z "$COMPONENT_PATH" ]; then
            print_info "Installation aborted by user"
            exit 1
        fi

        TEMP_DIR=$(mktemp -d)

        FILENAME="$PREFIX.zip"
        cp "$COMPONENT_PATH" "$TEMP_DIR/$FILENAME" || {
            print_error "Failed to copy zip file to temporary directory"
            exit 1
        }

        print_success "Using offline KDB-X file successfully!"
    else
        print_header "Downloading KDB-X"
        print_info "Fetching the latest stable version"

        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"

        FILENAME="$PREFIX.zip"
        FILEURL="https://portal.dl.kx.com/assets/raw/kdb-x/kdb-x/~latest~/$FILENAME"

        print_info "From: $FILEURL"

        if ! download_file "$FILEURL" "$FILENAME"; then
            print_error "Download failed. Please check your internet connection or permissions"
            cd - > /dev/null
            exit 1
        fi

        print_success "Downloaded successfully!"
        cd - > /dev/null
    fi
}

install_kdb() {
    print_header "Installing KDB-X"

    mkdir "$TEMP_DIR/install" "$TEMP_DIR/install/bin" "$TEMP_DIR/install/q" "$TEMP_DIR/install/lib" "$TEMP_DIR/install/mod" "$TEMP_DIR/install/mod/kx"

    print_info "Installing to temporary location: $TEMP_DIR/install"

    print_info "Extracting files"
    unzip -q -o "$TEMP_DIR/$FILENAME" -d "$TEMP_DIR/extracted" || {
        print_error "Failed to extract ZIP file. Please check if the file is valid"
        exit 1
    }

    Q_BINARY=$(find "$TEMP_DIR/extracted" -name "q" -type f -perm -u+x | head -1)

    if [ -z "$Q_BINARY" ]; then
        print_error "Could not find q binary in the extracted files"
        exit 1
    fi

    cp "$Q_BINARY" "$TEMP_DIR/install/bin/" || {
        print_error "Failed to copy q binary to $TEMP_DIR/install/bin"
        exit 1
    }

    chmod +x "$TEMP_DIR/install/bin/q" || {
        print_error "Failed to make q binary executable"
        exit 1
    }

    for Q_FILE in $(find "$TEMP_DIR/extracted" -name "*.q" -type f); do
        cp "$Q_FILE" "$TEMP_DIR/install/q/" 2>/dev/null || true
    done

    print_success "Installed successfully!"
}

test_license() {
    unset QHOME
    unset QLIC

    output=$(echo "exit 0" | "$TEMP_DIR/install/bin/q" -q 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        return 0
    fi

    echo "$output"
    return 1    
}

setup_license() {
    print_header "License setup"
    print_info   "A license file is required to run KDB-X"
    LIC_ATTEMPT=""
    while true; do
        if [ -z "$LIC_ATTEMPT" ]; then
            LIC_ATTEMPT=1
        else
            if [ "$ACCEPT_DEFAULTS" = true ]; then
                print_error "Cannot proceed in non-interactive mode: license validation failed"
                print_info "Please check your license and try again"
                exit 1
            fi
            show_menu "Try again" "Abort installation"
            case $? in
                0) ;;
                1) print_info "Installation aborted by user"; exit 0 ;;
            esac
        fi

        LICENSE_FILE=""
        if [ -n "$B64_LIC" ]; then
                print_green "Using --b64lic option:"
                print_info  "$B64_LIC"
            LICENSE_CONTENT="$B64_LIC"
            B64_LIC=""
            LICENSE_FILE="kc.lic"
        elif [ -n "$K4B64_LIC" ]; then
                print_green "Using --k4b64lic option:"
                print_info  "$K4B64_LIC"
            LICENSE_CONTENT="$K4B64_LIC"
            K4B64_LIC=""
            LICENSE_FILE="k4.lic"
        else
            print_header "License type"
            show_menu "kc.lic" "k4.lic"
            case $? in
                0) LICENSE_FILE="kc.lic" ;;
                1) LICENSE_FILE="k4.lic" ;;
            esac
            print_blue "Paste your base64 encoded license and press Enter:"
            read -r LICENSE_CONTENT
        fi
        if [ -n "$LICENSE_CONTENT" ]; then
            echo "$LICENSE_CONTENT" | base64 --decode > "$TEMP_DIR/install/$LICENSE_FILE" 2>/dev/null || {
                    print_error "Failed to decode license"
                continue
            }

            if err=$(test_license); then
                print_success "License file valid and working"
                break
            else
                    print_error "License validation failed: $err"
                rm -f "$TEMP_DIR/install/$LICENSE_FILE" 2>/dev/null || true
                continue
            fi
        else
                print_error "No license content provided"
            continue
        fi
    done
}

update_config_key() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    local description="${4:-$key}"  # Optional description

    if [ -z "$key" ] || [ -z "$value" ]; then
        print_error "update_config_key: key and value are required"
        return 1
    fi

    if [ ! -f "$config_file" ]; then
        print_error "Config file does not exist: $config_file"
        return 1
    fi

    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$config_file"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
        fi
        print_info "Updated $description setting in config file"
    else
        echo "${key}=${value}" >> "$config_file"
        print_info "Added $description setting to config file"
    fi

    return 0
}

setup_kdb_config_file() {
    local config_dir="$INSTALL_DIR"
    local config_file="$config_dir/config"

    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir" || {
            print_error "Failed to create config directory: $config_dir"
            return 1
        }
    fi

    if [ ! -f "$config_file" ]; then
        touch "$config_file" || {
            print_error "Failed to create config file: $config_file"
            return 1
        }
        print_info "Created config file: $config_file"
    else
        print_info "Config file already exists: $config_file"
        create_backup "$config_file" || {
            print_warning "Failed to create backup of config file"
        }
        CONFIG_FILE_MODIFIED="$config_file"
    fi

    # Add/Update KX_UPLOAD_TELEMETRY
    if [ -n "$QTEL_ENABLED" ]; then
        update_config_key "$config_file" "KX_UPLOAD_TELEMETRY" "$QTEL_ENABLED" "telemetry"
        print_success "Telemetry setting saved to: $config_file"
    fi

    return 0
}

# Check to see if `tld` is present in license
test_telemetry() {
    unset QHOME
    unset QLIC

    result=$(echo "any\"tld\"~/: \" \"vs .z.l[4]" | "$TEMP_DIR/install/bin/q" -q 2>/dev/null)
    
    if [ "$result" = "1b" ]; then
        return 0
    fi

    return 1
}

print_telemetry_notice_check(){
    result=$(echo "any\"tld\"~/: \" \"vs .z.l[4]" | "$TEMP_DIR/install/bin/q" -q 2>/dev/null)
    
    if [ "$result" = "1b" ]; then
        print_header "Telemetry Configuration"
        printf '%s\n' "$TELEMETRY_NO_PROMPT"
    fi
        return 0
}
setup_telemetry() {
    
    if test_telemetry; then
        QTEL_ENABLED="YES"
        #print_header "Telemetry Setup"
        #echo "You may turn off telemetry at any point by following the instructions in our" \
        # "Software documentation: https://code.kx.com/kdbx/releases/telemetry.html" \
        # "For more information on how we handle personal data, please refer to our Privacy" \
        # "Policy: https://kx.com/privacy-policy/"

        return 0
    fi

    print_header "Telemetry Configuration"

    if [ "$ACCEPT_DEFAULTS" = true ]; then
        QTEL_ENABLED="NO"
        print_info "Non-interactive mode: Telemetry disabled by default"
        return 0
    fi

    printf '%s\n' "$TELEMETRY_PROMPT"

    echo
    print_info "Would you like to enable usage telemetry?"

    read -p "${BLUE}Enable telemetry? (Y/N): " TELEMETRY_CHOICE
    printf $NC

    case "$TELEMETRY_CHOICE" in
        [Yy]|[Yy][Ee][Ss])
            QTEL_ENABLED="YES"
            print_success "Telemetry enabled - Thank you for helping us improve KDB-X!"
            ;;
        *)
            QTEL_ENABLED="NO"
            print_info "Telemetry disabled"
            ;;
    esac
}

install_module_generic() {
    local component_id="$1"      # "ai", "kurl", "rest", "dashboards"
    local display_name="$2"      # "AI module", "REST server module", "KX Dashboards"
    local url_path="$3"          # "modules/ai", "modules/rest-server", "dash"
    local filename="$4"          # "$PREFIX-ai.zip", "rest-server.zip", "KXDashboards.zip"
    local install_type="$5"      # "extract", "copy", or "custom"
    local target_path="$6"       # "$TEMP_DIR/install/mod/kx/ai"
    local override_path="${7:-}" # optional: skip download and use this local file directly (online mode only)

    if [ "$OFFLINE_MODE" = true ]; then
        get_offline_component "$component_id"
        if [ -z "$COMPONENT_PATH" ]; then
            print_warning "Continuing without $display_name"
            return 0
        fi

        if [ "$install_type" = "extract" ]; then
            if extract_component "$COMPONENT_PATH" "$target_path" "$component_id"; then
                print_success "Installed successfully!"
            else
                return 0
            fi
        elif [ "$install_type" = "copy" ]; then
            cp "$COMPONENT_PATH" "$target_path" || {
                print_warning "Failed to copy $display_name. Continuing without $display_name"
                return 0
            }
            print_success "Installed successfully!"
        elif [ "$install_type" = "custom" ]; then
            print_header "Handling $display_name (offline/custom)"
            local temp_file="$TEMP_DIR/${component_id}_${filename}"
            cp "$COMPONENT_PATH" "$temp_file" || {
                print_warning "Failed to copy $display_name to temp location. Continuing without $display_name"
                return 0
            }
            _install_module_generic_handle_custom "$component_id" "$temp_file" "$target_path"
            ret=$?
            rm -f "$temp_file"
            if [ $ret -ne 0 ]; then
                print_warning "Custom install handler failed for $component_id. Continuing without $display_name."
                return 0
            fi
        else
            print_warning "Unknown install type: $install_type. Skipping $display_name"
            return 0
        fi

    else
        local fileurl="https://portal.dl.kx.com/assets/raw/kdb-x/${url_path}/~latest~/${filename}"
        print_header "Downloading $display_name"    
        print_info "Fetching the latest stable version"
        print_info "From: $fileurl"
        if [ -n "$override_path" ]; then
            print_warning "Not using the download url: $fileurl - Using local test file: $override_path"
        fi            

        if [ "$install_type" = "extract" ]; then
            local temp_file="$TEMP_DIR/${component_id}_${filename}"
            if [ -n "$override_path" ] || download_file "$fileurl" "$temp_file"; then
                [ -n "$override_path" ] && temp_file="$override_path"
                print_header "Installing $display_name"
                if extract_component "$temp_file" "$target_path" "$component_id"; then
                    print_success "Installed successfully!"
                else
                    return 0
                fi
            else
                print_warning "Failed to download $display_name. Continuing without $display_name"
                return 0
            fi
        elif [ "$install_type" = "copy" ]; then
            if download_file "$fileurl" "$target_path"; then
                print_success "Installed successfully!"
            else
                print_warning "Failed to download $display_name. Continuing without $display_name"
                return 0
            fi
        elif [ "$install_type" = "custom" ]; then
            local temp_file="$TEMP_DIR/${component_id}_${filename}"
            if download_file "$fileurl" "$temp_file"; then
                print_header "Installing $display_name (custom handler)"
                _install_module_generic_handle_custom "$component_id" "$temp_file" "$target_path"
                rm -f "$temp_file"
            else
                print_warning "Failed to download $display_name. Continuing without $display_name"
                return 0
            fi
        else
            print_warning "Unknown install type: $install_type. Skipping $display_name"
            return 0
        fi
    fi
}

install_ai_module() {
    install_module_generic "ai" "AI module" "modules/ai" "$PREFIX-ai.zip" "extract" "$TEMP_DIR/install/mod/kx/ai"
}

install_kurl_module() {
    install_module_generic "kurl" "kurl module" "modules/kurl" "$PREFIX-kurl.zip" "extract" "$TEMP_DIR/install/mod/kx/kurl"
}

install_objstor_module() {
    install_module_generic "objstor" "objstor module" "modules/objstor" "$PREFIX-objstor.zip" "extract" "$TEMP_DIR/install/mod/kx/objstor"
}

install_rest_module() {
    # Test hook: In online mode, if local test file exists, pass it directly to install_module_generic
    # which will use it in place of downloading from the portal.
    local local_zip="/tmp/test_rest_server_zip/rest-server.zip"
    local override_path=""
    if [ "$OFFLINE_MODE" = false ] && [ -f "$local_zip" ]; then
        override_path="$local_zip"
    fi
    install_module_generic "rest" "REST server module" "modules/rest-server" "rest-server.zip" "extract" "$TEMP_DIR/install/mod/kx" "$override_path"
}

install_pq_module() {
    install_module_generic "pq" "parquet module" "modules/pq" "pq.zip" "extract" "$TEMP_DIR/install/mod/kx/pq"
}

install_sql_module() {
    install_module_generic "sql" "SQL module" "modules/sql" "$PREFIX-sql.zip" "custom" "$TEMP_DIR/install"
}

install_dashboards() {
    install_module_generic "dashboards" "KX Dashboards" "dash" "KXDashboards.zip" "extract" "$TEMP_DIR/install/dashboards"
}

check_existing_kdb_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "# KDB-X Installation Configuration" "$config_file" &&
        grep -q "# End KDB-X Installation Configuration" "$config_file"; then
        return 0  # Configuration block exists
    fi

    return 1  # No configuration block found
}

get_existing_kdb_config_content() {
    local config_file="$1"
    local content=""

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    content=$(awk '
        /# KDB-X Installation Configuration/ { in_block = 1; next }
        /# End KDB-X Installation Configuration/ { in_block = 0; next }
        in_block { print }
    ' "$config_file")

    echo "$content"
    return 0
}

line_exists_in_config() {
    local content="$1"
    local line_to_check="$2"

    local normalized_content=$(echo "$content" | sed 's/#.*$//' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local normalized_line=$(echo "$line_to_check" | sed 's/#.*$//' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    echo "$normalized_content" | grep -Fxq "$normalized_line"
}

get_missing_config_lines() {
    local config_file="$1"
    local existing_content
    local missing_lines=()

    existing_content=$(get_existing_kdb_config_content "$config_file")

    local path_line_normalized=$(echo "$NEW_PATH_LINE" | sed 's/#.*$//' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    if ! line_exists_in_config "$existing_content" "$path_line_normalized"; then
        missing_lines+=("$NEW_PATH_LINE")
    fi

    for var in QHOME QLIC QINIT; do
        eval "lines=(\"\${EXISTING_${var}_LINES[@]}\")"
        if [ ${#lines[@]} -gt 0 ]; then
            local unset_line
            case "$SHELL_TYPE" in
                fish) unset_line="set -e $var" ;;
                *)    unset_line="unset $var"  ;;
            esac
            if ! line_exists_in_config "$existing_content" "$unset_line"; then
                missing_lines+=("$unset_line  # Unset any previous $var setting")
            fi
        fi
    done

    for line in "${missing_lines[@]}"; do
        if [ -n "$line" ] && [ "$line" != " " ]; then
            echo "$line"
        fi
    done
}


detect_shell_config() {
    print_header "Detecting shell configuration"

    SHELL_TYPE=""

    if [ -n "$SHELL" ]; then
        SHELL_TYPE=$(basename "$SHELL")
        SHELL_TYPE="${SHELL_TYPE#-}"
    elif [ -n "$PPID" ]; then
        SHELL_TYPE=$(ps -o comm= -p "$PPID" | head -n 1)
        SHELL_TYPE="${SHELL_TYPE#-}"
    fi

    case "$SHELL_TYPE" in
        fish*) SHELL_TYPE="fish" ;;
        zsh*)  SHELL_TYPE="zsh"  ;;
        bash*) SHELL_TYPE="bash" ;;
        sh|ksh|tcsh|csh|dash)    ;;
        *) SHELL_TYPE="unknown"  ;;
    esac

    print_info "Detected shell: $SHELL_TYPE"

    SHELL_CONFIGS=()
    EXISTING_QHOME_LINES=()
    EXISTING_QLIC_LINES=()
    EXISTING_QINIT_LINES=()
    EXISTING_PATH_LINES=()

    case "$SHELL_TYPE" in
        bash)
            for f in "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
                [ -f "$f" ] && SHELL_CONFIGS+=("$f")
            done
            ;;
        zsh)
            for f in "$HOME/.zshrc" "$HOME/.zprofile"; do
                [ -f "$f" ] && SHELL_CONFIGS+=("$f")
            done
            ;;
        fish)
            [ -f "$HOME/.config/fish/config.fish" ] && SHELL_CONFIGS+=("$HOME/.config/fish/config.fish")
            ;;
        *)
            [ -f "$HOME/.profile" ] && SHELL_CONFIGS+=("$HOME/.profile")
            ;;
    esac

    if [ ${#SHELL_CONFIGS[@]} -eq 0 ]; then
        print_warning "No shell configuration files found"
        return 0
    fi

    print_info "Found configuration files:"
    for config in "${SHELL_CONFIGS[@]}"; do
        print_info "  - $config"
    done

    for config in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$config" ]; then
            while IFS= read -r line; do
                trimmed_line="${line%%\#*}"
                trimmed_line="${trimmed_line#"${trimmed_line%%[![:space:]]*}"}"
                if [[ -z "$trimmed_line" ]]; then
                    continue
                fi

                if [[ "$trimmed_line" =~ (export[[:space:]]+QHOME=|^[[:space:]]*QHOME=|set[[:space:]]+-gx[[:space:]]+QHOME) ]]; then
                    EXISTING_QHOME_LINES+=("$config:$line")
                elif [[ "$trimmed_line" =~ (export[[:space:]]+QLIC=|^[[:space:]]*QLIC=|set[[:space:]]+-gx[[:space:]]+QLIC) ]]; then
                    EXISTING_QLIC_LINES+=("$config:$line")
                elif [[ "$trimmed_line" =~ (export[[:space:]]+QINIT=|^[[:space:]]*QINIT=|set[[:space:]]+-gx[[:space:]]+QINIT) ]]; then
                    EXISTING_QINIT_LINES+=("$config:$line")
                fi
            done < "$config"

            while IFS= read -r line; do
                trimmed_line="${line%%\#*}"
                trimmed_line="${trimmed_line#"${trimmed_line%%[![:space:]]*}"}"
                if [[ -z "$trimmed_line" ]]; then
                    continue
                fi

                if [[ "$trimmed_line" =~ PATH.*([qQ]|kx|QHOME) ]]; then
                    EXISTING_PATH_LINES+=("$config:$line")
                fi
            done < "$config"
        fi
    done

    return 0
}

generate_replacement_lines() {
    case "$SHELL_TYPE" in
        fish)
            NEW_PATH_LINE="set -gx PATH \"$INSTALL_DIR/bin\" \$PATH"
            ;;
        *)
            NEW_PATH_LINE="export PATH=\"$INSTALL_DIR/bin:\$PATH\""
            ;;
    esac
}

create_backup() {
    local file="$1"
    local backup_file="$file.kdb_backup.$DTM"

    if cp "$file" "$backup_file"; then
        print_info "Created backup: $backup_file"
        return 0
    else
        print_error "Failed to create backup of $file"
        return 1
    fi
}

show_configuration_preview() {
    local target_config="$1"
    shift
    local missing_lines=("$@")

    if [ ${#missing_lines[@]} -eq 0 ]; then
        return 0
    fi

    print_header "Configuration changes needed"

    for var in QHOME QLIC QINIT; do
        eval "lines=(\"\${EXISTING_${var}_LINES[@]}\")"
        if [ ${#lines[@]} -gt 0 ]; then
            print_info "Existing $var lines found (will be unset):"
            for line in "${lines[@]}"; do
                IFS=':' read -r file content <<< "$line"
                print_info "  In $file: $content"
            done
            echo
        fi
    done

    print_info "Lines to be ADDED to $target_config:"
    for line in "${missing_lines[@]}"; do
        if [ -n "$line" ]; then
            print_green "    + $line"
        fi
    done
    echo

    print_info "This preserves existing configuration while ensuring the new KDB-X installation takes precedence"
}

apply_configuration_changes() {
    local target_config=""

    if [ ${#SHELL_CONFIGS[@]} -gt 0 ]; then
        target_config="${SHELL_CONFIGS[0]}"
    else
        case "$SHELL_TYPE" in
            zsh)  target_config="$HOME/.zshrc"  ;;
            bash) target_config="$HOME/.bashrc" ;;
            fish) target_config="$HOME/.config/fish/config.fish" ;;
            *)    target_config="$HOME/.profile" ;;
        esac
    fi

    if [ ! -f "$target_config" ]; then
        mkdir -p "$(dirname "$target_config")"
        touch "$target_config"
    fi

    if [ ! -w "$target_config" ]; then
        print_warning "Cannot write to configuration file: $target_config"
        print_info "Skipping environment setup - manual configuration required"
        print_info "You can run directly using: $INSTALL_DIR/bin/q"
        print_info ""
        print_info "To set up your environment manually, add these lines to your shell configuration:"
        print_info "  $NEW_PATH_LINE"
        print_info "  $NEW_Q_ALIAS_LINE"
        return 0
    fi

    local missing_lines=()
    if check_existing_kdb_config "$target_config"; then
        while IFS= read -r line; do
            missing_lines+=("$line")
        done < <(get_missing_config_lines "$target_config")
    else
        missing_lines=()

        for var in QHOME QLIC QINIT; do
            eval "lines=(\"\${EXISTING_${var}_LINES[@]}\")"
            if [ ${#lines[@]} -gt 0 ]; then
                case "$SHELL_TYPE" in
                    fish) missing_lines+=("set -e $var  # Unset any previous $var setting") ;;
                    *)    missing_lines+=("unset $var   # Unset any previous $var setting") ;;
                esac
            fi
        done

        missing_lines+=("$NEW_PATH_LINE")
    fi

    if [ ${#missing_lines[@]} -eq 0 ]; then
        print_info "All required configuration is already present - no changes needed!"
        print_success "Your configuration is complete and up-to-date."
        return 0
    fi

    show_configuration_preview "$target_config" "${missing_lines[@]}"

    show_menu "Apply these configuration changes now" "Skip (manual setup required later)"
    ENV_OPTION=$((1 + $?))  # Convert 0-based result to 1-based
    case $ENV_OPTION in
        1)
            create_backup "$target_config" || {
                print_error "Failed to create backup of $target_config"
                return 1
            }

            CONFIG_FILE_MODIFIED="$target_config"

            local config_header=""
            if check_existing_kdb_config "$target_config"; then
                config_header="# KDB-X Installation Configuration Update - $(date)"
            else
                config_header="# KDB-X Installation Configuration - $(date)"
            fi

            {
                echo ""
                echo "$config_header"
                for line in "${missing_lines[@]}"; do
                    echo "$line"
                done
                if ! check_existing_kdb_config "$target_config"; then
                    echo "# End KDB-X Installation Configuration"
                else
                    echo "# End KDB-X Installation Configuration Update"
                fi
            } >> "$target_config"

            print_success "Configuration changes applied successfully to $target_config"
            ;;
        2)
            print_warning "Environment setup skipped"
            print_info "You can run directly using: $INSTALL_DIR/bin/q"
            print_info ""
            print_info "To set up your environment manually, add the configuration lines shown above to your shell configuration"
            print_info "Note: QHOME and QLIC environment variables are no longer needed"
            ;;
    esac
}

setup_environment() {
    detect_shell_config
    generate_replacement_lines
    apply_configuration_changes
}


_install_module_generic_handle_custom() {
    local component_id="$1"
    local src_file="$2"
    local target_root="$3"

    if [ "$component_id" = "sql" ]; then
        local temp_extract="$TEMP_DIR/${component_id}_extract"
        mkdir -p "$temp_extract"
        if ! unzip -q -o "$src_file" -d "$temp_extract"; then
            print_warning "Failed to extract SQL module package. Skipping."
            rm -rf "$temp_extract"
            return 0
        fi

        local source_dir="$temp_extract"
        local entries=("$temp_extract"/*)
        if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ]; then
            source_dir="${entries[0]}"
        fi

        # Move pg into bin/
        if [ -f "$source_dir/pg" ]; then
            mkdir -p "$target_root/bin"
            if mv "$source_dir/pg" "$target_root/bin/" 2>/dev/null; then
                chmod +x "$target_root/bin/pg" 2>/dev/null || true
                print_info "Moved pg -> $target_root/bin/"
            else
                cp "$source_dir/pg" "$target_root/bin/" 2>/dev/null || print_warning "Could not move/copy pg"
                chmod +x "$target_root/bin/pg" 2>/dev/null || true
            fi
        fi

        # Move s.k_ into mod/kx/
        if [ -f "$source_dir/s.k_" ]; then
            mkdir -p "$target_root/q"
            if mv "$source_dir/s.k_" "$target_root/q/" 2>/dev/null; then
                print_info "Moved s.k_ -> $target_root/q/"
            else
                cp "$source_dir/s.k_" "$target_root/q/" 2>/dev/null || print_warning "Could not move/copy s.k_"
            fi
        fi

        # Remove changelog and readme files
        rm -f "$source_dir/changelog" \
              "$source_dir/readme" 2>/dev/null

        rm -rf "$temp_extract"
        print_success "Custom SQL module handling complete."
        return 0
    else
        print_error "Custom install requested for unsupported component: $component_id"
        print_info  "Please add custom install support for $component_id"
        return 1
    fi
}

verify_installation() {
    print_header "Verifying installation"

    INSTALLED_LICENSE=false
    INSTALLED_AI=false
    INSTALLED_KURL=false
    INSTALLED_OBJSTOR=false
    INSTALLED_PQ=false
    INSTALLED_REST=false
    INSTALLED_DASHBOARDS=false
    INSTALLED_SQL=false

    if [ ! -f "$TEMP_DIR/install/bin/q" ] || [ ! -x "$TEMP_DIR/install/bin/q" ]; then
        print_error "Installation verification failed: q binary missing or not executable"
        return 1
    fi

    if [ -f "$TEMP_DIR/install/kc.lic" ] || [ -f "$TEMP_DIR/install/k4.lic" ]; then
        print_info "License file found"
        if ! test_license; then
            print_warning "License file exists but may not be working properly"
        else
            print_info "License file valid and working"
            INSTALLED_LICENSE=true
        fi
    else
        print_warning "No license file found - you will need to add kc.lic/k4.lic before using KDB-X"
    fi

    if [ -d "$TEMP_DIR/install/mod/kx/ai" ] && [ -n "$(ls -A "$TEMP_DIR/install/mod/kx/ai" 2>/dev/null)" ]; then
        print_info "AI libraries installed"
        INSTALLED_AI=true
    fi

    if [ -d "$TEMP_DIR/install/mod/kx/kurl" ] && [ -n "$(ls -A "$TEMP_DIR/install/mod/kx/kurl" 2>/dev/null)" ]; then
        print_info "kurl module installed"
        INSTALLED_KURL=true
    fi

    if [ -d "$TEMP_DIR/install/mod/kx/objstor" ] && [ -n "$(ls -A "$TEMP_DIR/install/mod/kx/objstor" 2>/dev/null)" ]; then
        print_info "objstor module installed"
        INSTALLED_OBJSTOR=true
    fi

    if [ -d "$TEMP_DIR/install/mod/kx/pq" ] && [ -n "$(ls -A "$TEMP_DIR/install/mod/kx/pq" 2>/dev/null)" ]; then
        print_info "parquet module installed"
        INSTALLED_PQ=true
    fi

    if [ -f "$TEMP_DIR/install/bin/pg" ]; then
        print_info "postgres module installed"
    fi

    if [ -f "$TEMP_DIR/install/mod/kx/rest.q_" ]; then
        print_info "REST server module installed"
        INSTALLED_REST=true
    fi

    if [ -f "$TEMP_DIR/install/bin/pg" ] \
      && [ -x "$TEMP_DIR/install/bin/pg" ] \
      && [ -f "$TEMP_DIR/install/q/s.k_" ]; then
        print_info "SQL module installed"
        INSTALLED_SQL=true
    else
        print_warning "SQL module not fully installed (pg or s.k_ missing)"
    fi    

    if [ -d "$TEMP_DIR/install/dashboards" ] && [ -n "$(ls -A "$TEMP_DIR/install/dashboards" 2>/dev/null)" ]; then
        print_info "KX Dashboards installed"
        INSTALLED_DASHBOARDS=true
    fi

    print_success "Installation verified successfully!"
    return 0
}

finalize_installation() {
    print_header "Finalizing installation"

    if [ "$ARCHIVE_REQUIRED" = true ]; then
        archive_existing_installation
    fi

    if [ ! -e "$INSTALL_DIR" ]; then
        mkdir "$INSTALL_DIR" || {
            print_error "Failed to create installation directory"
            return 1
        }
        INSTALL_DIR_CREATED=true
    fi

    print_info "Moving installation files to final location"

    cp -r "$TEMP_DIR/install"/* "$INSTALL_DIR/" || {
        print_error "Failed to copy installation files"
        return 1
    }

    print_success "Installation finalized successfully!"
}

print_next_steps() {
    print_header "Installation complete"
    print_info "KDB-X has been installed to $INSTALL_DIR with the following structure:"
    print_info "  - $INSTALL_DIR/bin/              executable files (q)"
    print_info "  - $INSTALL_DIR/q/                code"
    print_info "  - $INSTALL_DIR/lib/              dynamic libraries (empty, for future use)"
    print_info "  - $INSTALL_DIR/mod/              modules directory"

    if [ "$INSTALLED_AI" = true ]; then
        print_info "  - $INSTALL_DIR/mod/kx/ai/        AI module"
    fi
    if [ "$INSTALLED_KURL" = true ]; then
        print_info "  - $INSTALL_DIR/mod/kx/kurl/      kurl module"
    fi
    if [ "$INSTALLED_OBJSTOR" = true ]; then
        print_info "  - $INSTALL_DIR/mod/kx/objstor/   objstor module"
    fi
    if [ "$INSTALLED_PQ" = true ]; then
        print_info "  - $INSTALL_DIR/mod/kx/pq/        parquet module"
    fi
    if [ "$INSTALLED_REST" = true ]; then
        print_info "  - $INSTALL_DIR/mod/kx/rest.q_    REST server module"
    fi
    if [ "$INSTALLED_SQL" = true ]; then
        print_info "  - $INSTALL_DIR/q/s.k_            SQL module"
    fi    
    if [ "$INSTALLED_DASHBOARDS" = true ]; then
        print_info "  - $INSTALL_DIR/dashboards/       KX Dashboards"
    fi
    if [ "$INSTALLED_LICENSE" = true ]; then
        print_info "  - $INSTALL_DIR/$LICENSE_FILE            license file"
    fi

    print_header "Next steps"
    if [ "$ENV_OPTION" = "1" ] && [ -n "$NEW_PATH_LINE" ]; then
        print_info "To start using 'q' command immediately:"
        print_info ""
        print_info "Reload your shell configuration:"
        case "$SHELL_TYPE" in
            bash)
                if [ -f "$HOME/.bash_profile" ]; then
                    print_blue "    source ~/.bash_profile"
                elif [ -f "$HOME/.bashrc" ]; then
                    print_blue "    source ~/.bashrc"
                else
                    print_blue "    source ~/.profile"
                fi
                ;;
            zsh)
                if [ -f "$HOME/.zshrc" ]; then
                    print_blue "    source ~/.zshrc"
                elif [ -f "$HOME/.zprofile" ]; then
                    print_blue "    source ~/.zprofile"
                else
                    print_blue "    source ~/.profile"
                fi
                ;;
            fish)
                if [ -f "$HOME/.config/fish/config.fish" ]; then
                    print_blue "    source ~/.config/fish/config.fish"
                else
                    print_blue "    source ~/.profile"
                fi
                ;;
            *)
                print_blue "    source ~/.profile"
                ;;
        esac
        print_info "Then you can simply run:"
        print_blue "    q"
    fi

    NEED_TO_UNSET=()
    for issue in "${EXISTING_ISSUES[@]}"; do
        if [[ "$issue" =~ "Existing \$QHOME envvar found:" ]]; then
            NEED_TO_UNSET+=("QHOME")
        elif [[ "$issue" =~ "Existing \$QLIC envvar found:" ]]; then
            NEED_TO_UNSET+=("QLIC")
        elif [[ "$issue" =~ "Existing \$QINIT envvar found:" ]]; then
            NEED_TO_UNSET+=("QINIT")
        fi
    done

    if [ ${#NEED_TO_UNSET[@]} -gt 0 ]; then
        print_warning "Important: You had existing environment variables that need to be unset:"
        print_info "In your current terminal session, run:"
        for var in "${NEED_TO_UNSET[@]}"; do
            print_blue "    unset $var"
        done
        print_info ""
        print_info "These variables are not set in your shell configuration files"
        print_info "However, they may still be set in your current session"
        print_info ""
    fi

    if [ -f "$INSTALL_DIR/kc.lic" ] || [ -f "$INSTALL_DIR/k4.lic" ]; then
        print_info "To run your first q program (\"Hello, World!\"):"
        if [ "$ENV_OPTION" = "1" ]; then
            print_blue "    q"
        else
            print_blue "    $INSTALL_DIR/bin/q"
        fi
        print_blue "    q)\"Hello, World!\""
    else
        print_warning "Before using KDB-X, add your license file as: $INSTALL_DIR/[kc|k4].lic"
    fi

    print_header "Resources"
    cat << EOF
Documentation: https://code.kx.com/q/
Tutorials: https://code.kx.com/q/learn/
VS Code Plugin: https://marketplace.visualstudio.com/items?itemName=kx.kdb

Stuck? Ask the Community: https://community.kx.com/
EOF
}

main() {
    check_args "$@"
    setup_error_trap
    clear
    print_header "Welcome to the KDB-X installer"
    check_prerequisites
    check_existing_installation
    check_platform
    set_install_dir
    ROLLBACK_REQUIRED=true
    download_kdb
    install_kdb
    setup_license
    setup_telemetry
    install_ai_module
    install_kurl_module
    install_objstor_module
    install_pq_module
    install_rest_module
    install_sql_module
    install_dashboards
    verify_installation
    finalize_installation
    setup_kdb_config_file
    setup_environment
    ROLLBACK_REQUIRED=false
    print_telemetry_notice_check
    print_next_steps
}
main "$@"
