#!/bin/bash

# Help message function
show_help() {
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  --force-refresh         Force refresh of the cached data."
	echo "  --user <email>          Manually override user lookup with the specified email."
	echo "  --sa <service-account>  Manually override service account lookup with the specified email."
	echo "  --project <project-id>  Specify the GCP project ID manually."
	echo "  --help                  Show this help message."
	echo ""
	echo "This script fetches IAM roles and users/service accounts for selected GCP projects."
	echo "You can select a project, IAM role, and user/service account using fzf."
}

# Define cache files and durations (e.g., 7 days)
ROLE_CACHE_FILE="/tmp/gcloud_iam_roles.cache"
USER_CACHE_FILE="/tmp/gcloud_users.cache"
CACHE_DURATION=$((7 * 24 * 60 * 60))

# Fetch project
fetch_project() {
	projects=$(gcloud projects list --format="value(projectId)")

	# Use fzf to select a project
	selected_project=$(echo "$projects" | fzf --prompt="Select Project: ")

	# Check if a project was selected
	if [ -z "$selected_project" ]; then
		echo "No project selected."
		exit 1
	fi
}

# Function to fetch roles
fetch_roles() {
	gcloud iam roles list --format="value(name)" >"$ROLE_CACHE_FILE"
}

# Function to fetch users and service accounts
fetch_users() {
	# Initialize variables to hold overrides
	user_override=""
	sa_override=""

	# Parse the input arguments
	while [[ $# -gt 0 ]]; do
		key="$1"
		case $key in
		--user)
			user_override="user:$2"
			shift # past argument
			shift # past value
			;;
		--sa)
			sa_override="serviceAccount:$2"
			shift # past argument
			shift # past value
			;;
		*)
			GCP_PROJECT_NAME="$1" # Assuming remaining arguments are project names
			shift                 # past argument
			;;
		esac
	done

	# Fetch service accounts and users from all projects specified in $GCP_PROJECT_NAME
	all_service_accounts=""
	all_users=""

	# Loop through each project name
	for project in $GCP_PROJECT_NAME; do
		# Fetch service accounts for the current project
		if [ -z "$sa_override" ]; then
			service_accounts=$(gcloud iam service-accounts list --project="$project" --format="value(email)")
			all_service_accounts+="$service_accounts"$'\n'
		fi

		# Fetch users for the current project
		if [ -z "$user_override" ]; then
			users=$(gcloud projects get-iam-policy "$project" --flatten="bindings[].members" --format="value(bindings.members)")
			all_users+="$users"$'\n'
		fi
	done

	# Combine service accounts and users, removing any duplicate entries
	if [ -n "$sa_override" ]; then
		combined_list="$sa_override"
	else
		combined_list=$(echo -e "$all_service_accounts" | sort | uniq)
	fi

	if [ -n "$user_override" ]; then
		combined_list+=$'\n'"$user_override"
	else
		combined_list+=$'\n'$(echo -e "$all_users" | sort | uniq)
	fi

	# Write the combined list to the cache file
	echo "$combined_list" >"$USER_CACHE_FILE"
}

# Parse arguments
FORCE_REFRESH=false
user_override=""
sa_override=""
project_specified=false

while [[ "$#" -gt 0 ]]; do
	case $1 in
	--force-refresh)
		FORCE_REFRESH=true
		shift
		;;
	--user)
		user_override="$2"
		shift 2
		;;
	--sa)
		sa_override="$2"
		shift 2
		;;
	--project)
		selected_project="$2"
		project_specified=true
		shift 2
		;;
	--help)
		show_help
		exit 0
		;;
	*)
		echo "Unknown parameter passed: $1"
		show_help
		exit 1
		;;
	esac
done

# Call fetch_project function to select a project if not specified
if [ "$project_specified" = false ]; then
	fetch_project
fi

# Check if cache files exist and are not too old, or if force refresh is enabled
current_time=$(date +%s)

if [ "$FORCE_REFRESH" = true ] || [ ! -f "$ROLE_CACHE_FILE" ] || [ $((current_time - $(stat -f %m "$ROLE_CACHE_FILE"))) -gt $CACHE_DURATION ]; then
	echo "Fetching IAM roles..."
	fetch_roles
else
	echo "Using cached IAM roles..."
fi

if [ "$FORCE_REFRESH" = true ] || [ ! -f "$USER_CACHE_FILE" ] || [ $((current_time - $(stat -f %m "$USER_CACHE_FILE"))) -gt $CACHE_DURATION ]; then
	echo "Fetching users and service accounts..."
	fetch_users --user "$user_override" --sa "$sa_override" "$selected_project"
else
	echo "Using cached users and service accounts..."
fi

# Read roles from cache
roles=$(cat "$ROLE_CACHE_FILE")

# Read users and service accounts from cache
users=$(cat "$USER_CACHE_FILE")

# Use fzf to select a role
selected_role=$(echo "$roles" | fzf --prompt="Select IAM Role: ")

# Check if a role was selected
if [ -z "$selected_role" ]; then
	echo "No IAM role selected."
	exit 1
fi

# Use fzf to select a user or service account
selected_user=$(echo "$users" | fzf --prompt="Select User or Service Account: ")

# Check if a user was selected
if [ -z "$selected_user" ]; then
	echo "No user or service account selected."
	exit 1
fi

# Use the selected project, role, and user/service account to add IAM policy binding
gcloud projects add-iam-policy-binding "$selected_project" \
	--member="$selected_user" \
	--role="$selected_role"

echo "IAM policy binding added for $selected_user with role $selected_role in project $selected_project"
