# PHP Release Builder

This is an attempt to standardize and automate most of the build process for PHP releases.

This container is currently based on `debian:jessie`.

![](php-build.jpg)

It will do the following:

- Ask for various inputs
  - Build version
  - Build date (for NEWS file)
  - Committer name & email
  - GPG Key fingerprint
  - SSH Key path
- Clone PHP from the official repo
- Create the release branch from the correct branch
- Update the version number/date in various files
- Build PHP
- Compare the build `-v` version against the intended version
- Run tests
- Tag the release, signed with your GPG key
- Push the tag and branches to origin
- Create the packages
- Generate GPG signatures & MD5 checksums
- Copy the resulting files to the docker host

## Running the Container

**You must run this container interactively.** In addition to the above inputs you will be asked for your
ssh key passphrase, and your gpg key passphrase numerous times.

You need to mount three host directories into the container at the following mount points:

1. `/secure/.ssh`: A directory containing the SSH key you need for git access
2. `/secure/.gnupg`: A directory containing your GPG keys
3. `/php-build`: A directory where the resulting packages/signatures will be saved

As an example, to run it using the default locations for SSH keys, and GPG keys:

```sh
docker run -it --rm -v$HOME/.ssh:/secure/.ssh -v$HOME/.gnupg:/secure/.gnupg -v$PWD:/php-build dshafik/php-build
```

This will pull the image from hub.docker.com and run it.

## Building the Container

If you want to build the container yourself, you can easily do so using the following command:

```sh
docker build -t $USER/php-build .
```

