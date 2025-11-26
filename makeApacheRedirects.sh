#!/usr/bin/bash
echo "Howdy! Welcome to my Apache2 Vhost tool!"
echo "This script is to set up website configs quick for new websites"
echo "because I'm tired of doing it manually all the time.  This script"
echo "will (you will need to be sudo user):"
echo "1. Ask a bunch of questions like domain name and document root"
echo "2. Create the directory if needed"
echo "3. Create the non-SSL HTTP VirtualHost"
echo "4. Restart apache"
echo "5. Run certbot to get a certificate installed"
echo "6. Create the SSL HTTPS VirtualHost"
echo "7. Update the non-SSL HTTP to redirect to the SSL VirtualHost"
echo "8. Restart apache"
echo "-------------------------------------------------------------------------------"

## Get information we'll need
echo "Please enter the domain name: "
read DOMAIN
## made the domain lower case it will help everyone involved
DOMAIN=$(echo $DOMAIN | tr '[:upper:]' '[:lower:]')

## Determine if it is normal or subdomain
DOTCOUNT=$(echo -n $DOMAIN | sed 's/[^\.]//g' | wc -c)
if [[ $DOTCOUNT == 1 ]]; then
	echo "This is a regular domain missing www";
	SUBDOMAIN='www';
else
	SUBDOMAIN=$(echo $DOMAIN | cut -d. -f1)
	if [[ "$SUBDOMAIN" == "www" ]]; then
		echo "This was entered in with www";
	else
		echo "This is domain that has a subdomain";
	fi
fi
DOMAIN=$(echo $DOMAIN | sed "s/$SUBDOMAIN\.//")
if [[ "$SUBDOMAIN" == "www" ]]; then
	FINALDOMAIN=$DOMAIN;
else
	FINALDOMAIN=$SUBDOMAIN.$DOMAIN;
fi

## Determine where the DOCROOT will be
echo "Please enter the document root [/var/www/html/$FINALDOMAIN]: "
read DOCROOT
if [[ "$DOCROOT" == "" ]]; then
	DOCROOT="/var/www/html/$FINALDOMAIN"
fi

## Assure the docroot exists
if [[ ! -d $DOCROOT ]]; then
	echo "The Document Root $DOCROOT does not exists, create it? [Y]:";
	read CREATEDIR
	if [[ "$CREATEDIR" == "" || "$CREATEDIR" == "y" || "$CREATEDIR" == "Y" ]]; then
		sudo -S mkdir $DOCROOT
		sudo -S chown $USER:developer $DOCROOT
		sudo -S chmod 0775 $DOCROOT
	fi
fi

## Get the non-SSL Apache config ready
echo "-------------------------------------------------------------------------------"
echo "Step 1: Non-SSL Apache VirtualHost config to listen to :80 while we do SSL cert"
NONWWW="<VirtualHost *:80>\n
	ServerName $FINALDOMAIN\n";
if [[ "$SUBDOMAIN" == "www" ]]; then 
	NONWWW="$NONWWW	ServerAlias $SUBDOMAIN.$DOMAIN\n";
fi
NONWWW="$NONWWW	DocumentRoot $DOCROOT\n</VirtualHost>";

## Attempt to set this up in apache, if not give instructions
VHOSTPATH="/etc/apache2/sites-available/$FINALDOMAIN.conf"
VHOSTEN="/etc/apache2/sites-enabled/$FINALDOMAIN.conf"
echo "Should I try to install this config? [Y]";
read INSTALL
if [[ "$INSTALL" == "" || "$INSTALL" == "y" || "$INSTALL" == "Y" ]]; then
	echo -e $NONWWW | sudo -S tee $VHOSTPATH;
	sudo -S ln -s $VHOSTPATH $VHOSTEN;
else
	echo "Okay, I didn't try to put the file into apache."
	echo "You will have to manually put this VirtualHost code in $VHOSTPATH"
	echo "And create a symbolic link from /etc/apache2/sites-enabled -> /etc/apache2/sites-available"
	echo -e $NONWWW;
fi

## Restart Apache
if [[ -f $VHOSTPATH && -f $VHOSTEN ]]; then
	echo "I have written the <VirtualHost> and linked from sites-enabled.";
	echo "Shall I restart apache now? [Y]: "
	read RESTART
	if [[ "$RESTART" == "" || "$RESTART" == "y" || "$RESTART" == "Y" ]]; then
		sudo -S service apache2 restart
	else
		echo "Did not restart apache, can't do anything else right now so quitting. Cya"
		exit;
	fi
else
	echo "The <VirtualHost> files did not write; not sure why.  Don't call Freddy.";
	exit;
fi

## Run certbot to get certificate installed
echo "Should I attempt to get an SSL certificate from certbot now? [Y]: ";
read DOCERT
if [[ "$DOCERT" == "" || "$DOCERT" == "y" || "$DOCERT" == "Y" ]]; then
	echo "Attempting to install SSL certificate from certbot"
	sudo -S certbot certonly --webroot -d $SUBDOMAIN.$DOMAIN --webroot-path $DOCROOT
else
	echo "Okay, I didn't try to create an SSL certificate; I'm thinking you already did this.";
fi

## Write the SSL HTTPS version of the VHost
WWW="<IfModule mod_ssl.c>\n
	<VirtualHost *:443>\n
		ServerName $SUBDOMAIN.$DOMAIN\n
		ServerAlias $DOMAIN\n
		DocumentRoot $DOCROOT\n
		ErrorLog \${APACHE_LOG_DIR}/$FINALDOMAIN.error.log\n
		CustomLog \${APACHE_LOG_DIR}/$FINALDOMAIN.access.log combined\n
		\n"
# only add this next line if the file already exists or else apache will not restart
if [[ -f /etc/letsencrypt/options-ssl-apache.conf ]]; then
 	WWW=$WWW"	Include /etc/letsencrypt/options-ssl-apache.conf\n";
fi
WWW=$WWW"	SSLCertificateFile /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/fullchain.pem\n
		SSLCertificateKeyFile /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/privkey.pem\n
	</VirtualHost>\n
</IfModule>\n";

## Update the HTTP version of the VHost
NONWWW="<VirtualHost *:80>\n
	ServerName $SUBDOMAIN.$DOMAIN\n
	\n
	RewriteEngine on\n
	RewriteCond %{SERVER_NAME} =$SUBDOMAIN.$DOMAIN\n
	RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]\n
</VirtualHost>\n
\n";
if [[ "$SUBDOMAIN" == "www" ]]; then
NONWWW="$NONWWW<VirtualHost *:80>\n
	ServerName $DOMAIN\n
	RedirectMatch permanent ^(.*) https://$SUBDOMAIN.$DOMAIN\$1\n
</VirtualHost>\n";
fi

## Install the new VirtualHost files
echo "Should I try to get the HTTPS VirtualHost files written? [Y]: "
read INSTALL
if [[ "$INSTALL" == "" || "$INSTALL" == "Y" || "$INSTALL" == "y" ]]; then
	## Write over the original HTTP version
	echo -e $NONWWW | sudo -S tee $VHOSTPATH;
	
	## Write the certbot required SSL 
	VHOSTPATH="/etc/apache2/sites-available/$FINALDOMAIN.conf-le-ssl.conf"
	VHOSTEN="/etc/apache2/sites-enabled/$FINALDOMAIN-le-ssl.conf"
	echo -e $WWW | sudo -S tee $VHOSTPATH;
	sudo -S ln -s $VHOSTPATH $VHOSTEN;
fi

## Restart Apache
if [[ -f $VHOSTPATH && -f $VHOSTEN ]]; then
	echo "I have written the HTTPS <VirtualHost> and linked from sites-enabled.";
	echo "Shall I restart apache now? [Y]: "
	read RESTART
	if [[ "$RESTART" == "" || "$RESTART" == "y" || "$RESTART" == "Y" ]]; then
		sudo -S service apache2 restart
	else
		echo "Did not restart apache, can't do anything else right now so quitting. Cya"
		exit;
	fi
else
	echo "The <VirtualHost> files did not write; not sure why.  Call Freddy.";
	exit;
fi
echo "Apache is: "$(sudo -S service apache2 status)
echo "I'm so done, dude."
exit;


