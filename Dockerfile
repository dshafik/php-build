# Build PHP releases with ease

# Build with: docker build -t $USER/php-build .
# Run with:
# docker run -it --rm -v$HOME/.ssh:/secure/.ssh -v$HOME/.gnupg:/secure/.gnupg -v$PWD:/php-build $USER/php-build
# This will mount your local .ssh and .gnupg directories, and use the PWD to output builds/signatures

FROM debian:jessie
MAINTAINER Davey Shafik <davey@php.net>
RUN apt-get update
RUN apt-get update --fix-missing
RUN echo "mysql-server mysql-server/root_password password \"''\"" | debconf-set-selections
RUN echo "mysql-server mysql-server/root_password_again password \"''\"" | debconf-set-selections
RUN apt-get install --yes build-essential
RUN apt-get install --yes mysql-server postgresql
RUN apt-get install --yes libgd-dev libxml2 libxslt1-dev libtidy-dev libreadline6 gettext libfreetype6
RUN apt-get install --yes git
RUN apt-get install --yes autoconf
RUN apt-get install --yes bison re2c
RUN apt-get install --yes openssl pkg-config libssl-dev
RUN apt-get install --yes libbz2-dev  libcurl4-openssl-dev libenchant-dev libgmp-dev libicu-dev libmcrypt-dev postgresql-server-dev-all libpspell-dev libreadline-dev
RUN apt-get install --yes gnupg wget
RUN ln -s /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h

ENV GNUPGHOME=/secure/.gnupg

VOLUME /secure/.ssh
VOLUME /secure/.gnupg
VOLUME /php-build

COPY ./build.sh /build.sh
CMD ["/build.sh"]
