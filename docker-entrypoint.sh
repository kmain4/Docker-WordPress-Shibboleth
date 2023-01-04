#!/usr/bin/env bash
set -Eeuo pipefail
cwd=$(pwd)
cd /tmp
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
wp cli update
curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.7.1/utils/wp-completion.bash
mv wp-completion.bash ~/.wp-completion.bash
echo "\nsource ~/.wp-completion.bash" > ~/.bash_profile
curl -o wordpress.tar.gz -fL "https://wordpress.org/wordpress-latest.tar.gz"; 
# upstream tarballs include ./wordpress/ so this gives us /usr/src/wordpress
tar -xzf wordpress.tar.gz -C /usr/src/; 
rm wordpress.tar.gz;
cd $cwd

# https://wordpress.org/support/article/htaccess/
[ ! -e /usr/src/wordpress/.htaccess ];
{ 
	echo '# BEGIN WordPress';
	echo '';
	echo 'RewriteEngine On';
	echo 'RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]';
	echo 'RewriteBase /';
	echo 'RewriteRule ^index\.php$ - [L]';
	echo 'RewriteCond %{REQUEST_FILENAME} !-f';
	echo 'RewriteCond %{REQUEST_FILENAME} !-d';
	echo 'RewriteRule . /index.php [L]';
	echo '';
	echo '# END WordPress';
} > /usr/src/wordpress/.htaccess;
chown -R www-data:www-data /usr/src/wordpress; 

if [[ "$1" == apache2* ]] || [ "$1" = 'php-fpm' ]; then
	uid="$(id -u)"
	gid="$(id -g)"
	if [ "$uid" = '0' ]; then
		case "$1" in
			apache2*)
				user="${APACHE_RUN_USER:-www-data}"
				group="${APACHE_RUN_GROUP:-www-data}"

				# strip off any '#' symbol ('#1000' is valid syntax for Apache)
				pound='#'
				user="${user#$pound}"
				group="${group#$pound}"
				;;
			*) # php-fpm
				user='www-data'
				group='www-data'
				;;
		esac
	else
		user="$uid"
		group="$gid"
	fi
    service shibd restart
    
	if [ ! -e index.php ] && [ ! -e wp-includes/version.php ]; then
		# if the directory exists and WordPress doesn't appear to be installed AND the permissions of it are root:root, let's chown it (likely a Docker-created directory)
		if [ "$uid" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
			chown "$user:$group" .
		fi

		echo >&2 "WordPress not found in $PWD - copying now..."
		if [ -n "$(find -mindepth 1 -maxdepth 1 -not -name wp-content)" ]; then
			echo >&2 "WARNING: $PWD is not empty! (copying anyhow)"
		fi
		sourceTarArgs=(
			--create
			--file -
			--directory /usr/src/wordpress
			--owner "$user" --group "$group"
		)
		targetTarArgs=(
			--extract
			--file -
		)
		if [ "$uid" != '0' ]; then
			# avoid "tar: .: Cannot utime: Operation not permitted" and "tar: .: Cannot change mode to rwxr-xr-x: Operation not permitted"
			targetTarArgs+=( --no-overwrite-dir )
		fi
		# loop over "pluggable" content in the source, and if it already exists in the destination, skip it
		# https://github.com/docker-library/wordpress/issues/506 ("wp-content" persisted, "akismet" updated, WordPress container restarted/recreated, "akismet" downgraded)
		for contentPath in \
			/usr/src/wordpress/.htaccess \
			/usr/src/wordpress/wp-content/*/*/ \
		; do
			contentPath="${contentPath%/}"
			[ -e "$contentPath" ] || continue
			contentPath="${contentPath#/usr/src/wordpress/}" # "wp-content/plugins/akismet", etc.
			if [ -e "$PWD/$contentPath" ]; then
				echo >&2 "WARNING: '$PWD/$contentPath' exists! (not copying the WordPress version)"
				sourceTarArgs+=( --exclude "./$contentPath" )
			fi
		done
		tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"
		echo >&2 "Complete! WordPress has been successfully copied to $PWD"
	fi
	if [ -n "$SERVICE_URL" ]; then 
                rm /etc/apache2/sites-enabled/000-default.conf 
                echo "<VirtualHost *:80>" >> /etc/apache2/sites-enabled/000-default.conf  
                echo "   ServerName https://$SERVICE_URL" >> /etc/apache2/sites-enabled/000-default.conf  
                echo "   ServerAlias $SERVICE_URL" >> /etc/apache2/sites-enabled/000-default.conf  
                echo "   ServerAdmin webmaster@$SERVICE_URL" >> /etc/apache2/sites-enabled/000-default.conf  
                echo "   DocumentRoot /var/www/html" >> /etc/apache2/sites-enabled/000-default.conf  
                echo '   ErrorLog ${APACHE_LOG_DIR}/error.log' >> /etc/apache2/sites-enabled/000-default.conf  
                echo '   CustomLog ${APACHE_LOG_DIR}/access.log combined' >> /etc/apache2/sites-enabled/000-default.conf 
       		echo "</VirtualHost>" >> /etc/apache2/sites-enabled/000-default.conf 
        fi
	wpEnvs=( "${!WORDPRESS_@}" )
	if [ ! -s wp-config.php ] && [ "${#wpEnvs[@]}" -gt 0 ]; then
		for wpConfigDocker in \
			wp-config-docker.php \
			/usr/src/wordpress/wp-config-docker.php \
		; do
            
            if [ -s "$wpConfigDocker" ]; then
				echo >&2 "No 'wp-config.php' found in $PWD, but 'WORDPRESS_...' variables supplied; copying '$wpConfigDocker' (${wpEnvs[*]})"
				# using "awk" to replace all instances of "put your unique phrase here" with a properly unique string (for AUTH_KEY and friends to have safe defaults if they aren't specified with environment variables)
				awk '
					/put your unique phrase here/ {
						cmd = "head -c1m /dev/urandom | sha1sum | cut -d\\  -f1"
						cmd | getline str
						close(cmd)
						gsub("put your unique phrase here", str)
					}
					{ print }
				' "$wpConfigDocker" > wp-config.php
				if [ "$uid" = '0' ]; then
					# attempt to ensure that wp-config.php is owned by the run user
					# could be on a filesystem that doesn't allow chown (like some NFS setups)
					chown "$user:$group" wp-config.php || true
				fi
				break
			fi
		done
	fi
fi

exec "$@"
