#!/bin/bash
trap ctrl_c INT
function ctrl_c() {
	exit -2
}

if [[ -f /config.env ]]
then
	source /config.env
fi

function run {
	read_version
	read_date
	read_committer
	read_gpg
	read_ssh_key

	msg_success "Building Version: $VERSION"
	set_committer "$COMMITTER_NAME" "$COMMITTER_EMAIL"
	check_date "$DATE"
	check_gpg "$GPG_KEY"
	check_ssh_key "$SSH_KEY"

	clone_php

	find_branch "$VERSION"
	# This function call creates VERSION_* variables
	get_version "$VERSION"

	create_release_branch "$VERSION"

	update_version \
		"$VERSION_MAJOR" "$VERSION_MINOR" "$VERSION_MICRO" \
		"$VERSION_EXTRA" "$VERSION_EXTRA_VERSION" "$VERSION_ID"
	update_news "$DATE"
	verify_changes
	commit_updates "$VERSION"

	compile_php
	run_tests

	# We do this after the tests so it is more visible
	compare_version "$VERSION"

	tag_release "$GPG_KEY" "$VERSION"
	push_branches "$ROOT_BRANCH" "$RELEASE_BRANCH" "$TAG_NAME"

	make_dist "$VERSION"

	gen_verify_stub "$VERSION"
	gen_md5_stub "$VERSION"

	move_files "$VERSION"

	msg_success "Build completed for php-${VERSION}!"

	read_next_ver
	update_news_next_ver "$ROOT_BRANCH" "$DATE" "$NEXT_VERSION"
	verify_changes
	commit_news_next_ver "$NEXT_VERSION"
	push_branches "$ROOT_BRANCH"
}

function read_with_default {
	msg -n "$2"
	if [[ ! -z "$3" ]]
	then
		msg -n " [$3]"
	fi
	msg -n ": "

	read READ_VALUE

	if [[ -z "$READ_VALUE" ]]
	then
		READ_VALUE="$3"
	fi

	local __RESULT_VAR=$1
	eval $__RESULT_VAR="'$READ_VALUE'"
}

function read_version {
	msg -n "PHP Version to build (e.g. 7.1.0beta2): "
	read VERSION
}

function read_date {
	local DEFAULT_DATE=$(date -d "+2 days" "+%d %b")
	read_with_default DATE "Release Date" "$DEFAULT_DATE"
}

function read_committer {
	read_with_default COMMITTER_NAME "Name" "$COMMITTER_NAME"
	read_with_default COMMITTER_EMAIL "Email Address" "$COMMITTER_EMAIL"
}

function read_gpg {
	read_with_default GPG_KEY "GPG Key Fingerprint" "$GPG_KEY"
}

function read_ssh_key {
	read_with_default SSH_KEY "SSH Key" ${SSH_KEY:-id_rsa}
}

function check_date {
	DATE=${1:-$(date -d "+2 days" "+%d %b")}
	msg_success "Using Date: $DATE"
}

function set_committer {
	msg_info "Setting committer to: $1 <$2>"
	git config --global user.name "$1"
	git config --global user.email "$2"
}

function check_ssh_key {
	if [[ -z $1 ]]
	then
		SSH_KEY=id_rsa
		msg_warn "Using default SSH key: $SSH_KEY"
	fi

	if [ ! -f "/secure/.ssh/$SSH_KEY" ]
	then
		 msg_error "SSH Key Not Found. Did you mount it?"
		 msg_info "Try running docker with:"
		 msg_info "-v\$HOME/.ssh:/secure/.ssh"
		 exit -1
	fi

	eval "$(ssh-agent -s)"
	ssh-add "/secure/.ssh/$SSH_KEY"
	if [[ $? -ne 0 ]]
	then
		msg_error "Failed to add SSH Key: $SSH_KEY"
		exit -1
	fi

	msg_success "Using SSH Key: $SSH_KEY"
}

function check_gpg {
	if [ ! -f "/secure/.gnupg/pubring.gpg" ]
	then
		msg_error "GPG Keys Not Found. Did you mount it?"
		msg_info "Try running docker with:"
		msg_info "-v\$HOME/.gnupg:/secure/.gnupg"
		exit -1
	fi

	VERIFY_KEY=`gpg --list-keys $1 2>/dev/null`
	if [[ $? -ne 0 ]]
	then
		msg_error "GPG Key \"$1\" Not Found"
		exit -1
	fi
	msg_success "GPG Key: $1"
}

function clone_php {
	if [[ -z $REPO_URL ]]
	then
		REPO_URL="git@git.php.net:php-src.git"
	fi
	msg_info "Using repo: $REPO_URL"
	git clone "$REPO_URL"
	cd php-src
}

function find_branch {
	# Check if on release branch
	git branch -a | grep -q "remotes/origin/PHP-$1$"
	if [[ $? -eq 0 ]]
	then
		msg_warn "Found existing release branch: PHP-$1"
		BRANCH_DEFAULT="PHP-$1"
	else
		local VERSION=$(echo $1 | cut -c 1-3)
		BRANCH_DEFAULT="PHP-$VERSION"
	fi

	git branch -a | grep -q "remotes/origin/$BRANCH_DEFAULT$"
	if [[ $? -ne 0 ]]
	then
		BRANCH_DEFAULT="master"
	fi

	read_with_default USE_BRANCH_DEFAULT "Which branch should be used to build from?" "$BRANCH_DEFAULT"

	if [[ -z "$USE_BRANCH_DEFAULT" ]]
	then
		USE_BRANCH_DEFAULT=BRANCH_DEFAULT
	fi

	git branch -a | grep -q "remotes/origin/$USE_BRANCH_DEFAULT$"
	if [[ $? -ne 0 ]]
	then
		msg_error "Branch \"$USE_BRANCH_DEFAULT\" not found."
		msg_error "Bailing out..."
		exit -1
	fi

	ROOT_BRANCH="$USE_BRANCH_DEFAULT"

	msg_success "Switching to branch $ROOT_BRANCH: "
	git checkout "$ROOT_BRANCH"
}

function get_version {
	VERSION_MAJOR=$(echo $1 | cut -d "." -f 1)
	VERSION_MINOR=$(echo $1 | cut -d "." -f 2)
	VERSION_MICRO=$(echo $1 | cut -d "." -f 3 | egrep -o "[0-9]+" | head -n 1)

	if [[ $VERSION_MICRO != $(echo $1 | cut -d "." -f 3) ]]
	then
		# This is an alpha/beta/RC
		OFFSET=${#VERSION_MICRO}
		OFFSET=$((OFFSET+1))
		VERSION_EXTRA=$(echo $1 | cut -d "." -f 3 | cut -c $OFFSET-)
		VERSION_EXTRA_VERSION=$(echo $VERSION_EXTRA | cut -d "." -f 3 | egrep -o "[0-9]+")
		VERSION_EXTRA=$(echo $VERSION_EXTRA | sed s/$VERSION_EXTRA_VERSION//g)
	fi

	VERSION_ID=$(($((VERSION_MAJOR*10000))+$((VERSION_MINOR*100))+$((VERSION_MICRO+0))))
}

function create_release_branch {
	RELEASE_BRANCH="PHP-$1"

	local CURRENT_BRANCH=$(git symbolic-ref -q HEAD | grep $RELEASE_BRANCH$)
	if [[ $? -ne 0 ]]
	then
		msg_info "Creating release branch PHP-$1"
		git checkout -b "$RELEASE_BRANCH"
	else
		msg_info "Already on release branch PHP-$1"
	fi
}

function update_version {
	# PHP 7.2 moved to configure.ac instead of configure.in
	CONFIGURE_AC="configure.ac"
	if [[ ! -f "configure.ac" ]]
	then
		CONFIGURE_AC="configure.in"
	fi

	msg_info -n "Updating main/php_version.h: "
	echo "/* automatically generated by configure */" > main/php_version.h
	echo "/* edit $CONFIGURE_AC to change version number */" >> main/php_version.h
	echo "#define PHP_MAJOR_VERSION $1" >> main/php_version.h
	echo "#define PHP_MINOR_VERSION $2" >> main/php_version.h
	echo "#define PHP_RELEASE_VERSION $3" >> main/php_version.h
	echo "#define PHP_EXTRA_VERSION \"$4$5\"" >> main/php_version.h
	echo "#define PHP_VERSION \"$1.$2.$3$4$5\"" >> main/php_version.h
	echo "#define PHP_VERSION_ID $6" >> main/php_version.h
	msg_success "done!"

	msg_info -n "Updating ${CONFIGURE_AC}: "
	sed -i "s/^PHP_MAJOR_VERSION=[0-9]\+$/PHP_MAJOR_VERSION=$1/g" "$CONFIGURE_AC"
	sed -i "s/^PHP_MINOR_VERSION=[0-9]\+$/PHP_MINOR_VERSION=$2/g" "$CONFIGURE_AC"
	sed -i "s/^PHP_RELEASE_VERSION=[0-9]\+$/PHP_RELEASE_VERSION=$3/g" "$CONFIGURE_AC"
	sed -i "s/^PHP_EXTRA_VERSION=\".\+\"$/PHP_EXTRA_VERSION=\"$4$5\"/g" "$CONFIGURE_AC"
	msg_success "done!"
}

function update_news {
	msg_info -n "Updating NEWS: "
	sed -i "s/^?? ???/$1/g" NEWS
	msg_success "done!"
}

function verify_changes {
	msg_info "Verify Changes"
	git diff
	msg_info -n "Does everything look good? [y/N]: "
	read VERIFY_CHANGES
	VERIFY_CHANGES=$(echo $VERIFY_CHANGES | tr "[:upper:]" "[:lower:]")
	if [[ -z "$VERIFY_CHANGES" || "$VERIFY_CHANGES" == n* ]]
	then
		msg_error "Bailing out..."
		exit -1
	fi
}

function commit_updates {
	msg_info "Committing Changes"
	git commit -a -m "Update versions/dates for PHP $1"
}

function compile_php {
	msg_info "Compiling PHP: "
	./travis/compile.sh > /dev/null
}

function run_tests {
	msg_info "Running Tests"
	sleep 3
	./sapi/cli/php run-tests.php -p `pwd`/sapi/cli/php -g "FAIL,XFAIL,BORK,WARN,LEAK,SKIP" --offline --show-diff --set-timeout 120
	msg_info -n "Does the output look good? [y/N] "
	read LOOKS_GOOD
	LOOKS_GOOD=$(echo "$LOOKS_GOOD" | tr "[:upper:]" "[:lower:]")
	if [[ -z "$LOOKS_GOOD" || "$LOOKS_GOOD" == n* ]]
	then
		msg_error "Bailing out..."
		exit -1
	fi
}

function compare_version {
	BUILD_VERSION=$(./sapi/cli/php -n -v | head -n 1 | cut -d " " -f 2)
	if [[ "$BUILD_VERSION" != "$1" ]]
	then
		msg_error "Build version \"$BUILD_VERSION\" doesn't match \"$1\""
		exit 1
	fi

	msg_success "Build version \"$BUILD_VERSION\" matches \"$1\""
}

function tag_release {
	TAG_NAME="php-$2"
	git tag -u $1 $TAG_NAME -m "Tag for $TAG_NAME"
	if [[ $? -ne 0 ]]
	then
		msg_error "Unable to tag!"
		exit -1
	fi

	msg_success "Tagged $TAG_NAME with key \"$1\" successfully!"
}

function push_branches {
	local UNIQUE_REFS=$(echo $@ | tr ' ' '\n' | sort -u | tr '\n' ' ')

	msg_info -n "Pushing branches: "
	git push origin $UNIQUE_REFS
	msg_warn "Skipping"
}

function make_dist {
	msg_info -n "Creating packages: "
	PHPROOT=. ./makedist "$1"
	if [[ $? -ne 0 ]]
	then
		msg_error "failed!"
		exit -1
	fi

	msg_success "done!"
}

function gen_verify_stub {
	msg_info "Generating GPG Signatures:"
	./scripts/dev/gen_verify_stub "$1"
}

function gen_md5_stub {
	msg_info "Generating MD5 Signatures:"
	md5sum "php-$1.tar"* | grep -v asc
}

function move_files {
	msg_info -n "Copying packages and signatures: "
	cp -R "php-$1.tar."* /php-build
	msg_info "done"
}

function read_next_ver {
	msg -n "Next PHP Version to build (e.g. 7.1.0beta2): "
	read NEXT_VERSION
}

function update_news_next_ver {
	local YEAR=$(date -d "+2 weeks" "+%Y")
	git checkout $1
	msg -n "Updating NEWS: "
	sed -i "s/^?? ???/$2/" NEWS
	awk "NR==3{print \"?? ??? $YEAR, PHP $3\n\n\n\"}7" NEWS > TMPNEWS
	mv TMPNEWS NEWS
	msg_success "done!"
}

function commit_news_next_ver {
	msg "Committing:"
	git add NEWS
	git commit -a -m "Update NEWS for $1"
}

function msg_with_color {
	local ESC_SEQ="\x1b["
	local RESET=$ESC_SEQ"39;49;00m"
	local COLOR="$ESC_SEQ$1"

	shift

	local ARGS=''
	if [[ $# -gt 1 ]]
	then
		ARGS=" $1"
		shift
	fi

	echo -e$ARGS "$COLOR$@$RESET"
}

function msg {
	msg_with_color "39;49;00m" "$@"
}

function msg_success {
	msg_with_color "32;01m" "$@"
}

function msg_info {
	msg_with_color "34;01m" "$@"
}

function msg_warn {
	msg_with_color "33;01m" "$@"
}

function msg_error {
	msg_with_color "31;01m" "$@"
}

run
