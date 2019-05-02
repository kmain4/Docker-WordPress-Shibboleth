# Docker-php-apache-shibboleth
This docker image is based on the Wordpress Apache image and installs libapache2-mod-shib2, configures apache2 to use shib and sets the relevant ServerName/ServerAlias.

You can provide the hostname for your WordPress environment using the `SERVICE_URL` environmental variable. Example: `SERVICE_URL=foobar.com`

All traditional Wordpress docker documentation applies: https://hub.docker.com/_/wordpress/
