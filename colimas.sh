#!/bin/bash

SERVICES_FILE="$HOME/.docker_services"
SERVICES_STATE_FILE="$HOME/.docker_services_state"

normalize_path() {
    local path="$1"
    local abs_path
    
    if [[ "$path" =~ /\./?$ ]]; then
        path=$(dirname "$path")
    fi
    
    if [[ "$path" = /* ]]; then
        abs_path="$path"
    else
        abs_path="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    fi
    
    echo "${abs_path%/}"
}

get_service_name() {
    local path="$1"
    if [[ "$path" =~ /\./?$ ]]; then
        dirname "$path" | xargs basename
    else
        basename "$path"
    fi
}

get_service_path() {
    local service_name="$1"
    if [ -f "$SERVICES_FILE" ]; then
        local exact_match=$(grep "^.*/$service_name\$" "$SERVICES_FILE")
        if [ -n "$exact_match" ]; then
            echo "$exact_match"
            return
        fi
        
        while IFS= read -r path; do
            if [ "$(get_service_name "$path")" = "$service_name" ]; then
                echo "$path"
                return
            fi
        done < "$SERVICES_FILE"
    fi
}

set_service_state() {
    local service_path="$1"
    local state="$2"
    local tmp_file=$(mktemp)
    
    if [ -f "$SERVICES_STATE_FILE" ]; then
        grep -v "^$service_path:" "$SERVICES_STATE_FILE" > "$tmp_file" 2>/dev/null
    fi
    echo "$service_path:$state" >> "$tmp_file"
    mv "$tmp_file" "$SERVICES_STATE_FILE"
}

get_service_state() {
    local service_path="$1"
    if [ -f "$SERVICES_STATE_FILE" ]; then
        grep "^$service_path:" "$SERVICES_STATE_FILE" | cut -d':' -f2
    else
        echo "stopped"
    fi
}

list_services() {
    if [ -f "$SERVICES_FILE" ]; then
        local GREEN="\033[0;32m"
        local RED="\033[0;31m"
        local YELLOW="\033[0;33m"
        local BLUE="\033[0;34m"
        local GRAY="\033[0;90m"
        local NC="\033[0m"
        local BOLD="\033[1m"
                
        printf "${BOLD}Colima Services Overview${NC}\n"
        
        while IFS= read -r service_path; do
            local service_name=$(get_service_name "$service_path")
            local status_color="$RED"
            local status_text="Not Found"
            local running_status="No"
            
            if [ -d "$service_path" ]; then
                status_text="Exists"
                status_color="$YELLOW"
                if docker-compose -f "$service_path/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
                    running_status="Yes"
                    status_text="Running"
                    status_color="$GREEN"
                else
                    status_text="Stopped"
                    status_color="$RED"
                fi
            fi
            
            printf "\n${BLUE}%-25s${NC} ${status_color}%-12s${NC} ${GRAY}%s${NC}\n" \
                "$service_name" \
                "$status_text" \
                "$service_path"
            
            if [ "$status_text" = "Running" ] && [ -f "$service_path/docker-compose.yml" ]; then
                cd "$service_path" && docker-compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" | \
                while IFS= read -r line; do
                    if [[ ! "$line" =~ ^Name && ! "$line" =~ ^--- ]]; then
                        printf "  ${GRAY}└─${NC} %s\n" "$line"
                    fi
                done
            fi
        done < "$SERVICES_FILE"
    else
        echo -e "\n${YELLOW}No services are currently registered.${NC}\n"
    fi
}

record_service() {
    local service_path="$(normalize_path "$1")"
    if ! grep -q "^$service_path$" "$SERVICES_FILE" 2>/dev/null; then
        echo "$service_path" >> "$SERVICES_FILE"
        set_service_state "$service_path" "running"
        echo "Service at $service_path recorded"
    fi
}

remove_service() {
    local input_path="$1"
    local service_path
    
    if [[ ! "$input_path" =~ ^/ && ! "$input_path" =~ ^\./ ]]; then
        service_path=$(get_service_path "$input_path")
        if [ -z "$service_path" ]; then
            echo "Error: Service '$input_path' not found"
            return 1
        fi
    else
        service_path="$(normalize_path "$input_path")"
    fi
    
    if [ -f "$SERVICES_FILE" ]; then
        sed -i '' "\#^$service_path\$#d" "$SERVICES_FILE"
        if [ -f "$SERVICES_STATE_FILE" ]; then
            sed -i '' "\#^$service_path:#d" "$SERVICES_STATE_FILE"
        fi
        echo "Service at $service_path removed from records"
    fi
}

start_compose_service() {
    local service_path="$(normalize_path "$1")"
    if [ -d "$service_path" ]; then
        echo "Starting service at $service_path..."
        cd "$service_path" || return 1
        if docker-compose up -d; then
            set_service_state "$service_path" "running"
            return 0
        fi
    else
        echo "Error: Directory $service_path does not exist"
    fi
    return 1
}

stop_compose_service() {
    local service_path="$(normalize_path "$1")"
    local preserve_state="${2:-false}"
    if [ -d "$service_path" ]; then
        echo "Stopping service at $service_path..."
        cd "$service_path" || return 1
        if docker-compose stop; then
            if [ "$preserve_state" = "false" ]; then
                set_service_state "$service_path" "stopped"
            fi
            return 0
        fi
    else
        echo "Error: Directory $service_path does not exist"
    fi
    return 1
}

restore_services() {
    if [ -f "$SERVICES_FILE" ]; then
        echo "Restoring recorded services..."
        while IFS= read -r service_path; do
            local state=$(get_service_state "$service_path")
            if [ "$state" = "running" ]; then
                start_compose_service "$service_path"
            else
                echo "Skipping $service_path (state: $state)"
            fi
        done < "$SERVICES_FILE"
    fi
}

start_services() {
    echo "Starting Colima..."
    colima start
    
    restore_services
    
    echo "Services started successfully!"
}

stop_services() {
    if [ -f "$SERVICES_FILE" ]; then
        echo "Stopping all recorded services..."
        while IFS= read -r service_path; do
            stop_compose_service "$service_path" "true"
        done < "$SERVICES_FILE"
    fi
    
    echo "Stopping Colima..."
    colima stop
    echo "Colima stopped successfully!"
}

confirm_action() {
    local message="$1"
    read -p "$message (y/N): " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

watch_service_logs() {
    local service_path="$(normalize_path "$1")"
    if [ -d "$service_path" ]; then
        echo "Watching logs for service at $service_path..."
        cd "$service_path" || return 1
        docker-compose logs -f
        return 0
    else
        echo "Error: Directory $service_path does not exist"
        return 1
    fi
}

stats_service() {
    local service_path="$(normalize_path "$1")"
    if [ -d "$service_path" ]; then
        echo "Showing stats for service at $service_path..."
        cd "$service_path" || return 1
        local container_ids=$(docker-compose ps -q)
        if [ -n "$container_ids" ]; then
            docker stats $container_ids
            return 0
        else
            echo "No running containers found for this service"
            return 1
        fi
    else
        echo "Error: Directory $service_path does not exist"
        return 1
    fi
}

show_help() {
    local GREEN="\033[0;32m"
    local BLUE="\033[0;34m"
    local GRAY="\033[0;90m"
    local NC="\033[0m"
    local BOLD="\033[1m"
    
    printf "${BOLD}Colima Services Manager${NC}\n"
    
    printf "\n${BOLD}Usage:${NC}\n"
    printf "  ${BLUE}colimas${NC} ${GRAY}[command] [options]${NC}\n"
    
    printf "\n${BOLD}Commands:${NC}\n"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "start" "up,s" "Start Colima and all services marked as running"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "start <name>" "up,s" "Start a specific service"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "stop" "down,d" "Stop all services and Colima"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "stop <name>" "down,d" "Stop a specific service"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "add <path>" "a" "Add and start a new Docker Compose service"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "remove <name>" "rm,r" "Stop, remove containers, and unregister a service"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "list" "ls,l" "Show all registered services and their status"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "log <name>" "logs" "Watch logs of all containers in a service"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "stats <name>" "st" "Show container stats (CPU, Memory, Network, etc.)"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "make" "m" "Install this script as system-wide 'colimas' command"
    printf "  ${BLUE}%-15s${NC} ${GRAY}%-10s${NC} %s\n" \
        "help" "h,?" "Show this help message"
    
    printf "\n${BOLD}Notes:${NC}\n"
    printf "  ${GRAY}•${NC} Paths can be absolute or relative to the current directory\n"
    printf "  ${GRAY}•${NC} Service names are derived from the last directory name of the service path\n"
    printf "  ${GRAY}•${NC} Services state is preserved between restarts\n"
}

if [ $# -eq 0 ] || [ "$1" = "start" ] || [ "$1" = "up" ] || [ "$1" = "s" ] && [ $# -eq 1 ]; then
    start_services
elif [ "$1" = "start" ] || [ "$1" = "up" ] || [ "$1" = "s" ] && [ -n "$2" ]; then
    service_path=$(get_service_path "$2")
    if [ -n "$service_path" ]; then
        start_compose_service "$service_path"
    else
        echo "Error: Service '$2' not found"
        exit 1
    fi
elif [ "$1" = "stop" ] || [ "$1" = "down" ] || [ "$1" = "d" ] && [ $# -eq 1 ]; then
    stop_services
elif [ "$1" = "stop" ] || [ "$1" = "down" ] || [ "$1" = "d" ] && [ -n "$2" ]; then
    service_path=$(get_service_path "$2")
    if [ -n "$service_path" ]; then
        stop_compose_service "$service_path" "false"
    else
        echo "Error: Service '$2' not found"
        exit 1
    fi
elif [ "$1" = "add" ] || [ "$1" = "a" ] && [ -n "$2" ]; then
    service_path="$(normalize_path "$2")"
    if [ -d "$service_path" ]; then
        record_service "$service_path"
        start_compose_service "$service_path"
    else
        echo "Error: Directory $service_path does not exist"
        exit 1
    fi
elif [ "$1" = "remove" ] || [ "$1" = "rm" ] || [ "$1" = "r" ] && [ -n "$2" ]; then
    service_path=$(get_service_path "$2")
    if [ -n "$service_path" ]; then
        if confirm_action "Are you sure you want to remove $2 and destroy its containers?"; then
            cd "$service_path" && docker-compose down
            remove_service "$service_path"
        else
            echo "Operation cancelled"
            exit 1
        fi
    else
        echo "Error: Service '$2' not found"
        exit 1
    fi
elif [ "$1" = "list" ] || [ "$1" = "ls" ] || [ "$1" = "l" ]; then
    list_services
elif [ "$1" = "log" ] || [ "$1" = "logs" ] && [ -n "$2" ]; then
    service_path=$(get_service_path "$2")
    if [ -n "$service_path" ]; then
        watch_service_logs "$service_path"
    else
        echo "Error: Service '$2' not found"
        exit 1
    fi
elif [ "$1" = "stats" ] || [ "$1" = "st" ] && [ -n "$2" ]; then
    service_path=$(get_service_path "$2")
    if [ -n "$service_path" ]; then
        stats_service "$service_path"
    else
        echo "Error: Service '$2' not found"
        exit 1
    fi
elif [ "$1" = "make" ] || [ "$1" = "m" ]; then
    echo "Installing script as system executable 'colimas'..."
    if [ "$EUID" -ne 0 ]; then
        echo "This operation requires root privileges. Please enter your password:"
        if sudo cp "$0" /usr/local/bin/colimas && sudo chmod +x /usr/local/bin/colimas; then
            echo "Successfully installed as 'colimas' in /usr/local/bin"
            echo "You can now use 'colimas' command from anywhere"
        else
            echo "Failed to install the script"
            exit 1
        fi
    else
        if cp "$0" /usr/local/bin/colimas && chmod +x /usr/local/bin/colimas; then
            echo "Successfully installed as 'colimas' in /usr/local/bin"
            echo "You can now use 'colimas' command from anywhere"
        else
            echo "Failed to install the script"
            exit 1
        fi
    fi
elif [ "$1" = "help" ] || [ "$1" = "h" ] || [ "$1" = "?" ]; then
    show_help
elif [ -z "$1" ]; then
    show_help
else
    echo "Error: Invalid command '$1'"
fi
