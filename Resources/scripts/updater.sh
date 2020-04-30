#!/bin/bash
# Executed when the master branch of PokeAPI/pokeapi gets updated
# Runs in CircleCI
# Generates new data using the latest changes of PokeAPI/pokeapi in order to open a Pull Request towards PokeAPI/api-data

set -o pipefail

org='PokeAPI'
data_repo='api-data'
engine_repo='pokeapi'
branch_name='updated-data'
username='pokeapi-machine-user'
email='pokeapi.co@gmail.com'

function cleanexit {
	echo "Exiting"
	echo "$2"
  if [ "$1" -gt "0" ]; then
    notify_engine_pr "end_failed"
  else
    notify_engine_pr "end_success"
  fi
	exit $1
}

# Create and use a personal folder
prepare() {
  mkdir -p ./repositories
  cd repositories || cleanexit 1 "Failed to cd"
}

# Not used
# Check and return the number of the Pull Request that started this job
get_invokator_pr_number() {
  if [ -z "$CIRCLE_PULL_REQUEST" ]; then
    echo "${CIRCLE_PULL_REQUEST##*/}"
  fi
}

# Clone the repository containing the static JSON files
clone() {
  git clone "https://github.com/${org}/${data_repo}.git" "$data_repo"
}

# Configure git to use the supplied user when committing
configure_git() {
  git config --global user.name "$username"
  git config --global user.email "$email"
}

pr_input_updater_start() {
  cat <<EOF
{
  "body": "A [PokeAPI/api-data](https://github.com/PokeAPI/api-data) refresh has started. If everything works out in 30 minutes a Pull Request will be created and assigned to the PokeAPI Core team to be reviewed. If approved and merged new data will soon be available worldwide."
}
EOF
}

pr_input_updater_end_success() {
  cat <<EOF
{
  "body": "The updater script has finished its job and has opened a Pull Request [PokeAPI/api-data](https://github.com/PokeAPI/api-data) with the updated data."
}
EOF
}

pr_input_updater_end_failed() {
  cat <<EOF
{
  "body": "The updater script couldn't finish it's job. Please check CircleCI's logs."
}
EOF
}

# If the job was started by a Pull Request add a comment to notify the users
notify_engine_pr() {
  if [[ $1 == "start" || $1 == "end" ]]; then
    if ! [ -z "$CIRCLE_PULL_REQUEST" ]; then
      engine_repo_pr_number="${CIRCLE_PULL_REQUEST##*/}"
      curl -f -H "Authorization: token $MACHINE_USER_GITHUB_API_TOKEN" -X POST --data "$(pr_input_updater_$1)" "https://api.github.com/repos/$org/$engine_repo/issues/${engine_repo_pr_number}/comments"
    fi
  fi
}

# Run the updater script (https://github.com/PokeAPI/api-data/blob/master/updater/cmd.bash) which will generate the new pokeapi data and push it to the api-data repository under a new branch
run_updater() {
  cd "${data_repo}/updater" || cleanexit 1 "Failed to cd"

  # Wait to be sure PokeAPI/pokeapi:origin/master has been updated on Github with the lastest merged PR content
  sleep 10

  # Build the updater image
  docker build -t pokeapi-updater .
  if [ $? -ne 0 ]; then
    cleanexit 1 "Failed to build the pokeapi-updater image"
  fi

  # Run the updater
  docker run --privileged -e COMMIT_EMAIL="$email" -e COMMIT_NAME="$username" -e BRANCH_NAME="$branch_name" -e REPO_POKEAPI="https://github.com/${org}/${engine_repo}.git" -e REPO_DATA="https://${MACHINE_USER_GITHUB_API_TOKEN}@github.com/${org}/${data_repo}.git" pokeapi-updater
  if [ $? -ne 0 ]; then
    cleanexit 1 "Failed to run the pokeapi-updater container"
  fi

  cd .. || cleanexit 1 "Failed to cd"
}

# Check if the updater script has pushed the data to a new branch
check_remote_branch() {
  # Wait for Github to update origin/${branch_name}
  sleep 10

  curl -f -H "Authorization: token $MACHINE_USER_GITHUB_API_TOKEN" -X GET "https://api.github.com/repos/$org/$data_repo/branches/$1"
  if [ $? -ne 0 ]; then
    cleanexit 1 "The updater script failed to push the new data"
  fi
}

pr_input_content() {
  cat <<EOF
{
  "title": "API data update",
  "body": "Incoming data generated by https://github.com/${org}/${engine_repo} CircleCI worker",
  "head": "$branch_name",
  "base": "master",
  "assignees": [
    "Naramsim"
  ],
  "labels": [
    "api-data-update"
  ]
}
EOF
}

# Create a Pull Request to merge the branch recently pushed by the updater with the master branch
create_pr() {
  data_repo_pr_number=$(curl -H "Authorization: token $MACHINE_USER_GITHUB_API_TOKEN" -X POST --data "$(pr_input_content)" "https://api.github.com/repos/$org/$data_repo/pulls" | jq '.number')
  if [[ "$data_repo_pr_number" = "null" ]]; then
    cleanexit 1 "Couldn't create the Pull Request"
  fi
  echo "$data_repo_pr_number"
}

pr_input_assignees_and_labels() {
  cat <<EOF
{
  "assignees": [
    "Naramsim"
  ],
  "labels": [
    "api-data-update"
  ]
}
EOF
}

# Assign the PR to Naramsim and add a label
customize_pr() {
  # Wait for Github to open the PR
  sleep 10
  
  data_repo_pr_number=$1
  curl -H "Authorization: token $MACHINE_USER_GITHUB_API_TOKEN" -X PATCH --data "$(pr_input_assignees_and_labels)" "https://api.github.com/repos/$org/$data_repo/issues/$data_repo_pr_number"
  if [ $? -ne 0 ]; then
		echo "Couldn't add Assignees and Labes to the Pull Request"
	fi
}

pr_input_reviewers() {
  cat <<EOF
{
  "reviewers": [
    "Naramsim"
  ],
  "team_reviewers": [
    "core-team"
  ]
}
EOF
}

# Request the Core team to review the Pull Request
add_reviewers_to_pr() {
  data_repo_pr_number=$1
  curl -H "Authorization: token $MACHINE_USER_GITHUB_API_TOKEN" -X POST --data "$(pr_input_reviewers)" "https://api.github.com/repos/$org/$data_repo/pulls/$data_repo_pr_number/requested_reviewers"
  if [ $? -ne 0 ]; then
    echo "Couldn't add Reviewers to the Pull Request"
  fi
}

prepare
clone
configure_git
notify_engine_pr "start"
run_updater
check_remote_branch "$branch_name"
data_repo_pr_number=$(create_pr)
customize_pr "$data_repo_pr_number"
add_reviewers_to_pr "$data_repo_pr_number"
cleanexit 0 'Done'
