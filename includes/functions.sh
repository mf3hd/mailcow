textb() { echo $(tput bold)${1}$(tput sgr0); }
greenb() { echo $(tput bold)$(tput setaf 2)${1}$(tput sgr0); }
redb() { echo $(tput bold)$(tput setaf 1)${1}$(tput sgr0); }
yellowb() { echo $(tput bold)$(tput setaf 3)${1}$(tput sgr0); }
pinkb() { echo $(tput bold)$(tput setaf 5)${1}$(tput sgr0); }

usage() {
	echo "mailcow install script command-line parameters."
	echo $(textb "Do not append any parameters to run mailcow in default mode.")
 	echo "./install.sh [ACTION] [PARAMETERS]"
	echo '
	ACTIONS:
	-h | -?
		Print this text

	-u
		Upgrade mailcow to a newer version

	-U
		Upgrade mailcow to a newer version
		and do not ask to press any key to continue


	PARAMETERS:
	Note: Only available when upgrading
		-H hostname
			Overwrite hostname detection

		-D example.org
			Overwrite domain detection

	EXAMPLES:
		Upgrade using mail.example.org as FQDN:
		./install.sh -u -H mail -D example.org
	'
}

genpasswd() {
	count=0
	while [ $count -lt 3 ]; do
		pw_valid=$(tr -cd A-Za-z0-9 < /dev/urandom | fold -w24 | head -n1)
		count=$(grep -o "[0-9]" <<< $pw_valid | wc -l)
	done
	echo $pw_valid
}

returnwait() {
	echo "$(greenb [OK]) - Task $(textb "$1") completed"
	echo "----------------------------------------------"
	if [[ ${inst_confirm_proceed} == "yes" ]]; then
		read -p "$(yellowb !) Press ENTER to continue with task $(textb "$2") (CTRL-C to abort) "
	fi
	echo "$(pinkb [RUNNING]) - Task $(textb "$2") started, please wait..."
}

checksystem() {
	if [[ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 800000 ]]; then
		echo "$(yellowb [WARN]) - At least 800MB of memory is highly recommended"
		read -p "Press ENTER to skip this warning or CTRL-C to cancel the process"
	fi
	[[ ! -z $(ip -6 addr | grep "scope global") ]] && IPV6="yes"

}

checkports() {
	if [[ -z $(which nc) ]]; then
		echo "$(redb [ERR]) - Please install $(textb netcat) before running this script"
		exit 1
	fi
	for port in 25 143 465 587 993 995 8983
	do
		if [[ $(nc -z localhost $port; echo $?) -eq 0 ]]; then
			echo "$(redb [ERR]) - An application is blocking the installation on Port $(textb $port)"
			# Wait until finished to list all blocked ports.
			blocked_port=1
		fi
	done
	[[ $blocked_port -eq 1 ]] && exit 1
	if [[ -z $(which mysql) ]];then
		echo "$(textb [INFO]) - Installing prerequisites for port checks"
		apt-get -y update > /dev/null ; apt-get -y install mysql-client > /dev/null 2>&1
	fi
	if [[ $(nc -z ${my_dbhost} 3306; echo $?) -eq 0 ]] && [[ $(mysql --host ${my_dbhost} -u root -p${my_rootpw} -e ""; echo $?) -ne 0 ]]; then
		echo "$(redb [ERR]) - Cannot connect to SQL database server at ${my_dbhost} with given root password"
		exit 1
	elif [[ $(nc -z ${my_dbhost} 3306; echo $?) -eq 0 ]] && [[ $(mysql --host ${my_dbhost} -u root -p${my_rootpw} -e ""; echo $?) -eq 0 ]]; then
		if [[ -z $(mysql --host ${my_dbhost} -u root -p${my_rootpw} -e "SHOW GRANTS" | grep "WITH GRANT OPTION") ]]; then
			echo "$(redb [ERR]) - SQL root user is missing GRANT OPTION"
			exit 1
		fi
		echo "$(textb [INFO]) - Successfully connected to SQL server at ${my_dbhost}"
		echo
		if [[ ${my_dbhost} == "localhost" || ${my_dbhost} == "127.0.0.1" ]] && [[ -z $(mysql -V | grep -i "mariadb") && $my_usemariadb == "yes" ]]; then
			echo "$(redb [ERR]) - Found MySQL server but \"my_usemariadb\" is \"yes\""
			exit 1
		elif [[ ${my_dbhost} == "localhost" || ${my_dbhost} == "127.0.0.1" ]] && [[ ! -z $(mysql -V | grep -i "mariadb") && $my_usemariadb != "yes" ]]; then
			echo "$(redb [ERR]) - Found MariaDB server but \"my_usemariadb\" is not \"yes\""
			exit 1
		fi
		mysql_useable=1
	fi
}

checkconfig() {
	for var in sys_hostname sys_domain sys_timezone my_dbhost my_mailcowdb my_mailcowuser my_mailcowpass my_rootpw mailcow_admin_user mailcow_admin_pass
	do
		if [[ -z ${!var} ]]; then
			echo "$(redb [ERR]) - Parameter $var must not be empty."
			echo
			exit 1
		fi
	done
	pass_count=$(grep -o "[0-9]" <<< $mailcow_admin_pass | wc -l)
	pass_chars=$(echo $mailcow_admin_pass | egrep "^.{8,255}" | \
	egrep "[ABCDEFGHIJKLMNOPQRSTUVXYZ]" | \
	egrep "[abcdefghijklmnopqrstuvxyz"] | \
	egrep "[0-9]")
	if [[ $pass_count -lt 2 || -z $pass_chars ]]; then
		echo "$(redb [ERR]) - mailcow administrator password does not meet password policy requirements (8 char., 2 num., UPPER- + lowercase)"
		echo
		exit 1
	fi
	if [[ $inst_debug == "yes" ]]; then
		set -x
	fi
	if [[ -z $(which rsyslogd) ]]; then
		echo "$(redb [ERR]) - Please install rsyslogd"
		echo
		exit 1
	fi
}

installtask() {
	case $1 in
		environment)
			[[ -z $(grep fs.inotify.max_user_instances /etc/sysctl.conf) ]] && echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf
			sysctl -p > /dev/null 2>&1
			if [[ -f /usr/share/zoneinfo/${sys_timezone} ]] ; then
				echo ${sys_timezone} > /etc/timezone
				dpkg-reconfigure -f noninteractive tzdata > /dev/null 2>&1
				if [ "$?" -ne "0" ]; then
					echo "$(redb [ERR]) - Timezone configuration failed: dpkg returned exit code != 0"
					exit 1
				fi
			else
				echo "$(redb [ERR]) - Cannot set your timezone: timezone is unknown"
				exit 1
			fi
			mkdir -p /var/mailcow/log;
			;;
		installpackages)
			echo "$(textb [INFO]) - Installing prerequisites..."
			apt-get -y update > /dev/null ; apt-get -y install lsb-release whiptail apt-utils ssl-cert > /dev/null 2>&1
        		dist_codename=$(lsb_release -cs)
			dist_id=$(lsb_release -is)
			if [[ $dist_id == "Debian" ]]; then
				apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7638D0442B90D010 > /dev/null 2>&1
				apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 8B48AD6246925553 > /dev/null 2>&1
			fi
			/usr/sbin/make-ssl-cert generate-default-snakeoil --force-overwrite
			# Detect and edit repos
			if [[ $dist_codename == "trusty" ]]; then
				echo "$(textb [INFO]) - Adding ondrej/apache2 repository..."
				echo "deb http://ppa.launchpad.net/ondrej/apache2/ubuntu trusty main" > /etc/apt/sources.list.d/ondrej.list
				apt-key adv --keyserver keyserver.ubuntu.com --recv E5267A6C > /dev/null 2>&1
				echo "$(textb [INFO]) - Adding official SOGo repository..."
				echo "deb http://inverse.ca/ubuntu trusty trusty" > /etc/apt/sources.list.d/sogo.list
				apt-key adv --keyserver keys.gnupg.net --recv-key 0x810273C4 > /dev/null 2>&1
				apt-get -y update >/dev/null
			elif [[ $dist_codename == "jessie" ]]; then
				echo "$(textb [INFO]) - Adding official SOGo repository..."
				echo "deb http://inverse.ca/debian jessie jessie" > /etc/apt/sources.list.d/sogo.list
				apt-key adv --keyserver keys.gnupg.net --recv-key 0x810273C4 > /dev/null 2>&1
				apt-get -y update >/dev/null
			fi
			echo "$(textb [INFO]) - Installing packages unattended, please stand by, errors will be reported."
			if [[ $(lsb_release -is) == "Ubuntu" ]]; then
				echo "$(yellowb [WARN]) - You are running Ubuntu. The installation will not fail, though you may see a lot of output until the installation is finished."
			fi
			apt-get -y update >/dev/null
			if [[ ${my_dbhost} == "localhost" || ${my_dbhost} == "127.0.0.1" ]] && [[ $is_upgradetask != "yes" ]]; then
				if [[ $my_usemariadb == "yes" ]]; then
					database_backend="mariadb-client mariadb-server"
				else
					database_backend="mysql-client mysql-server"
				fi
			else
				database_backend=""
			fi
DEBIAN_FRONTEND=noninteractive apt-get --force-yes -y install zip dnsutils python-setuptools libmail-spf-perl libmail-dkim-perl file \
openssl php-auth-sasl php-http-request php-mail php-mail-mime php-mail-mimedecode php-net-dime php-net-smtp \
php-net-socket php-net-url php-pear php-soap php5 php5-cli php5-common php5-curl php5-gd php5-imap php-apc subversion \
php5-intl php5-xsl libawl-php php5-mcrypt php5-mysql php5-sqlite libawl-php php5-xmlrpc ${database_backend} mailutils pyzor razor \
postfix postfix-mysql postfix-pcre postgrey pflogsumm spamassassin spamc sudo bzip2 curl mpack opendkim opendkim-tools unzip clamav-daemon \
python-magic unrar-free liblockfile-simple-perl libdbi-perl libmime-base64-urlsafe-perl libtest-tempdir-perl liblogger-syslog-perl bsd-mailx \
openjdk-7-jre-headless libcurl4-openssl-dev libexpat1-dev rrdtool mailgraph fcgiwrap spawn-fcgi \
solr-jetty apache2 apache2-utils libapache2-mod-php5 sogo sogo-activesync libwbxml2-0 memcached > /dev/null
			if [ "$?" -ne "0" ]; then
				echo "$(redb [ERR]) - Package installation failed"
				exit 1
			fi
			update-alternatives --set mailx /usr/bin/bsd-mailx --quiet > /dev/null 2>&1
			mkdir -p /etc/dovecot/private/
			cp /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/dovecot/dovecot.pem
			cp /etc/ssl/private/ssl-cert-snakeoil.key /etc/dovecot/dovecot.key
			cp /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/dovecot/private/dovecot.pem
			cp /etc/ssl/private/ssl-cert-snakeoil.key /etc/dovecot/private/dovecot.key
			if [[ ! -z $(grep wheezy-backports /etc/apt/sources.list) ]]; then
				echo "$(textb [INFO]) - Installing Dovecot from wheezy-backports..."
DEBIAN_FRONTEND=noninteractive apt-get --force-yes -y install dovecot-common dovecot-core dovecot-imapd dovecot-lmtpd dovecot-managesieved dovecot-sieve dovecot-mysql dovecot-pop3d dovecot-solr -t wheezy-backports >/dev/null
			else
DEBIAN_FRONTEND=noninteractive apt-get --force-yes -y install dovecot-common dovecot-core dovecot-imapd dovecot-lmtpd dovecot-managesieved dovecot-sieve dovecot-mysql dovecot-pop3d dovecot-solr >/dev/null
			fi
			# Installing mailcow binaries
			install -m 755 misc/mc_clean_spam_aliases /etc/cron.daily/mc_clean_spam_aliases
			install -m 755 misc/mc_pfset /usr/local/sbin/mc_pfset
			install -m 755 misc/mc_pflog_renew /usr/local/sbin/mc_pflog_renew
			install -m 755 misc/mc_msg_size /usr/local/sbin/mc_msg_size
			install -m 755 misc/mc_dkim_ctrl /usr/local/sbin/mc_dkim_ctrl
			install -m 755 misc/mc_setup_backup /usr/local/sbin/mc_setup_backup
			install -m 755 misc/mc_resetadmin /usr/local/sbin/mc_resetadmin
			;;
		ssl)
			mkdir /etc/ssl/mail 2> /dev/null
			rm /etc/ssl/mail/* 2> /dev/null
			echo "$(textb [INFO]) - Generating 2048 bit DH parameters, this may take a while, please wait..."
			openssl dhparam -out /etc/ssl/mail/dhparams.pem 2048 2> /dev/null
			if [[ ${httpd_lets_encrypt} == "yes" ]]; then
				echo "$(textb [INFO]) - Requesting certificates from Let's Encrypt..."
				service apache2 stop 2> /dev/null
				wget https://github.com/letsencrypt/letsencrypt/archive/v${letsencrypt}.tar.gz -O - | tar xfz -
				./letsencrypt-${letsencrypt}/letsencrypt-auto certonly --standalone -d ${sys_hostname}.${sys_domain} -d autodiscover.${sys_domain}
				echo "$(textb [INFO]) - Searching for useable certificate..."
				if [[ -d /etc/letsencrypt/live ]]; then
					for i in $(ls /etc/letsencrypt/live); do
						if [[ ! -z $(openssl x509 -in "/etc/letsencrypt/live/$i/fullchain.pem" -text -noout | \
							grep -E "DNS:autodiscover.${sys_domain}" | \
							grep -E "DNS:${sys_hostname}.${sys_domain}") ]]; then
									LE_CERT_PATH="/etc/letsencrypt/live/$i"
									break
						fi
					done
					if [[ -z ${LE_CERT_PATH} ]]; then
						LETS_FAILED="1"
						echo "$(yellowb [WARN]) - Cannot find a proper certificate path, falling back to self-signed..."
					else
						ln -s ${LE_CERT_PATH}/fullchain.pem /etc/ssl/mail/mail.crt
						ln -s ${LE_CERT_PATH}/privkey.pem /etc/ssl/mail/mail.key
						echo "$(textb [INFO]) - Found useable certificates"
					fi
				else
					LETS_FAILED="1"
					echo "$(yellowb [WARN]) - Let's Encrypt request failed, falling back to self-signed certificates..."
				fi
				rm -r letsencrypt-${letsencrypt}
			fi
			if [[ ${LETS_FAILED} == "1" ]] || [[ ${httpd_lets_encrypt} != "yes" ]]; then
				openssl req -new -newkey rsa:4096 -sha256 -days 1095 -nodes -x509 -subj "/C=ZZ/ST=mailcow/L=mailcow/O=mailcow/CN=${sys_hostname}.${sys_domain}/subjectAltName=DNS.1=${sys_hostname}.${sys_domain},DNS.2=autodiscover.{sys_domain}" -keyout /etc/ssl/mail/mail.key -out /etc/ssl/mail/mail.crt
				chmod 600 /etc/ssl/mail/mail.key
				cp /etc/ssl/mail/mail.crt /usr/local/share/ca-certificates/
				update-ca-certificates
			fi
			;;
		mysql)
			if [[ $mysql_useable -ne 1 ]]; then
				mysql --defaults-file=/etc/mysql/debian.cnf -e "UPDATE mysql.user SET Password=PASSWORD('$my_rootpw') WHERE USER='root'; FLUSH PRIVILEGES;"
			fi
			mysql --host ${my_dbhost} -u root -p${my_rootpw} -e "DROP DATABASE IF EXISTS ${my_mailcowdb};"
			mysql --host ${my_dbhost} -u root -p${my_rootpw} -e "CREATE DATABASE ${my_mailcowdb}; GRANT ALL ON ${my_mailcowdb}.* TO '${my_mailcowuser}'@'%' IDENTIFIED BY '${my_mailcowpass}';"
			mysql --host ${my_dbhost} -u root -p${my_rootpw} -e "GRANT SELECT ON ${my_mailcowdb}.* TO 'vmail'@'%'; FLUSH PRIVILEGES;"
			;;
		postfix)
			mkdir -p /etc/postfix/sql
			chown root:postfix "/etc/postfix/sql"; chmod 750 "/etc/postfix/sql"
			for file in $(ls postfix/conf/sql)
			do
				install -o root -g postfix -m 640 postfix/conf/sql/$file /etc/postfix/sql/$file
			done
			install -m 644 postfix/conf/master.cf /etc/postfix/master.cf
			install -m 644 postfix/conf/main.cf /etc/postfix/main.cf
			install -o www-data -g www-data -m 644 postfix/conf/mailcow_anonymize_headers.pcre /etc/postfix/mailcow_anonymize_headers.pcre
			install -m 644 postfix/conf/postscreen_access.cidr /etc/postfix/postscreen_access.cidr
			sed -i "s/sys_hostname.sys_domain/${sys_hostname}.${sys_domain}/g" /etc/postfix/main.cf
			sed -i "s/sys_domain/${sys_domain}/g" /etc/postfix/main.cf
			sed -i "s/my_mailcowpass/${my_mailcowpass}/g" /etc/postfix/sql/*
			sed -i "s/my_mailcowuser/${my_mailcowuser}/g" /etc/postfix/sql/*
			sed -i "s/my_mailcowdb/${my_mailcowdb}/g" /etc/postfix/sql/*
			sed -i "s/my_dbhost/${my_dbhost}/g" /etc/postfix/sql/*
			sed -i '/^POSTGREY_OPTS=/s/=.*/="--inet=127.0.0.1:10023"/' /etc/default/postgrey
			chmod 755 /var/spool/
			sed -i "/%www-data/d" /etc/sudoers 2> /dev/null
			sed -i "/%vmail/d" /etc/sudoers 2> /dev/null
			echo '%www-data ALL=(ALL) NOPASSWD: /usr/bin/doveadm * sync *, /usr/local/sbin/mc_pfset *, /usr/bin/doveadm quota recalc -A, /usr/sbin/dovecot reload, /usr/sbin/postfix reload, /usr/local/sbin/mc_dkim_ctrl, /usr/local/sbin/mc_msg_size, /usr/local/sbin/mc_pflog_renew, /usr/local/sbin/mc_setup_backup' >> /etc/sudoers
			;;
		fuglu)
			if [[ -z $(grep fuglu /etc/passwd) ]]; then
				userdel fuglu 2> /dev/null
				groupadd fuglu 2> /dev/null
				useradd -g fuglu -s /bin/false fuglu
				usermod -a -G debian-spamd fuglu
				usermod -a -G clamav fuglu
			fi
			rm /tmp/fuglu_control.sock 2> /dev/null
			mkdir /var/log/fuglu 2> /dev/null
			chown fuglu:fuglu /var/log/fuglu
			tar xf fuglu/inst/$fuglu_version.tar -C fuglu/inst/ 2> /dev/null
			(cd fuglu/inst/$fuglu_version ; python setup.py -q install)
			cp -R fuglu/conf/* /etc/fuglu/
			if [[ -f /lib/systemd/systemd ]]; then
				cp fuglu/inst/$fuglu_version/scripts/startscripts/debian/8/fuglu.service /etc/systemd/system/fuglu.service
				systemctl disable fuglu
				[[ -f /lib/systemd/system/fuglu.service ]] && rm /lib/systemd/system/fuglu.service
				systemctl daemon-reload
				systemctl enable fuglu
			else
				install -m 755 fuglu/inst/$fuglu_version/scripts/startscripts/debian/7/fuglu /etc/init.d/fuglu
				update-rc.d fuglu defaults
			fi
			rm -rf fuglu/inst/$fuglu_version
			;;
		dovecot)
			if [[ -f /lib/systemd/systemd ]]; then
				systemctl disable dovecot.socket > /dev/null 2>&1
			fi
			if [[ -z $(grep '/var/vmail:' /etc/passwd | grep '5000:5000') ]]; then
				userdel vmail 2> /dev/null
				groupdel vmail 2> /dev/null
				groupadd -g 5000 vmail
				useradd -g vmail -u 5000 vmail -d /var/vmail
			fi
			chmod 755 "/etc/dovecot/"
			install -o root -g dovecot -m 640 dovecot/conf/dovecot-dict-sql.conf /etc/dovecot/dovecot-dict-sql.conf
			install -o root -g vmail -m 640 dovecot/conf/dovecot-mysql.conf /etc/dovecot/dovecot-mysql.conf
			install -m 644 dovecot/conf/dovecot.conf /etc/dovecot/dovecot.conf
			DOVEFILES=$(find /etc/dovecot -maxdepth 1 -type f -printf '/etc/dovecot/%f ')
			sed -i "s/MAILCOW_HOST.MAILCOW_DOMAIN/${sys_hostname}.${sys_domain}/g" ${DOVEFILES}
			sed -i "s/MAILCOW_DOMAIN/${sys_domain}/g" ${DOVEFILES}
			sed -i "s/my_mailcowpass/${my_mailcowpass}/g" ${DOVEFILES}
			sed -i "s/my_mailcowuser/${my_mailcowuser}/g" ${DOVEFILES}
			sed -i "s/my_mailcowdb/${my_mailcowdb}/g" ${DOVEFILES}
			sed -i "s/my_dbhost/${my_dbhost}/g" ${DOVEFILES}
			[[ ${IPV6} != "yes" ]] && sed -i '/listen =/c\listen = *' /etc/dovecot/dovecot.conf
			mkdir /etc/dovecot/conf.d 2> /dev/null
			mkdir -p /var/vmail/sieve 2> /dev/null
			install -m 644 dovecot/conf/global.sieve /var/vmail/sieve/global.sieve
			touch /var/vmail/sieve/default.sieve
			sievec /var/vmail/sieve/global.sieve
			chown -R vmail:vmail /var/vmail
			[[ -f /etc/cron.daily/doverecalcq ]] && rm /etc/cron.daily/doverecalcq
			install -m 755 dovecot/conf/dovemaint /etc/cron.daily/
			install -m 644 dovecot/conf/solrmaint /etc/cron.d/
			# Solr
			#if [[ -z $(curl -s --connect-timeout 3 "http://127.0.0.1:8983/solr/admin/info/system" 2> /dev/null | grep -o '[0-9.]*' | grep "^${solr_version}\$") ]]; then
			#	(
			#	TMPSOLR=$(mktemp -d)
			#	cd $TMPSOLR
			#	MIRRORS_SOLR=(http://mirror.23media.de/apache/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://mirror2.shellbot.com/apache/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://mirrors.koehn.com/apache/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://mirrors.sonic.net/apache/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://apache.mirrors.ovh.net/ftp.apache.org/dist/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://mirror.nohup.it/apache/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://ftp-stud.hs-esslingen.de/pub/Mirrors/ftp.apache.org/dist/lucene/solr/${solr_version}/solr-${solr_version}.tgz
			#	http://mirror.netcologne.de/apache.org/lucene/solr/${solr_version}/solr-${solr_version}.tgz)
			#	for i in "${MIRRORS_SOLR[@]}"; do
			#		if curl --connect-timeout 3 --output /dev/null --silent --head --fail "$i"; then
			#			SOLR_URL="$i"
			#			break
			#		fi
			#	done
			#	if [[ -z ${SOLR_URL} ]]; then
			#		echo "$(redb [ERR]) - No Solr mirror was usable"
			#		exit 1
			#	fi
			#	echo $(textb "Downloading Solr ${solr_version}...")
			#	curl ${SOLR_URL} -# | tar xfz -
			#	if [[ ! -d /opt/solr ]]; then
			#		mkdir /opt/solr/
			#	fi
			#	cp -R solr-${solr_version}/* /opt/solr
			#	rm -r ${TMPSOLR}
			#	)
			#	if [[ ! -d /var/solr ]]; then
			#		mkdir /var/solr/
			#	fi
			#	if [[ ! -f /var/solr/solr.in.sh ]]; then
			#	install -m 644 /opt/solr/bin/solr.in.sh /var/solr/solr.in.sh
			#	sed -i '/SOLR_HOST/c\SOLR_HOST=127.0.0.1' /var/solr/solr.in.sh
			#	sed -i '/SOLR_PORT/c\SOLR_PORT=8983' /var/solr/solr.in.sh
			#	sed -i "/SOLR_TIMEZONE/c\SOLR_TIMEZONE=\"${sys_timezone}\"" /var/solr/solr.in.sh
			#	[[ -z $(grep "jetty.host=localhost" /var/solr/solr.in.sh) ]] && echo 'SOLR_OPTS="$SOLR_OPTS -Djetty.host=localhost"' >> /var/solr/solr.in.sh
			#fi
			#if [[ ! -f /etc/init.d/solr ]]; then
			#	install -m 755 /opt/solr/bin/init.d/solr /etc/init.d/solr
			#	update-rc.d solr defaults
			#	if [[ -f /lib/systemd/systemd ]]; then
			#		systemctl daemon-reload
			#	fi
			#fi
			#if [[ -z $(grep solr /etc/passwd) ]]; then
			#	useradd -r -d /opt/solr solr
			#fi
			#chown -R solr: /opt/solr
			#service solr restart
			#sleep 2
			#if [[ ! -d /opt/solr/server/solr/dovecot2/ ]]; then
			#	sudo -u solr /opt/solr/bin/solr create -c dovecot2
			#fi
			#fi
			update-rc.d -f solr remove > /dev/null 2>&1
			service solr stop > /dev/null 2>&1
			cp /usr/share/dovecot/solr-schema.xml /etc/solr/conf/schema.xml
			sed -i '/NO_START/c\NO_START=0' /etc/default/jetty8
                        sed -i '/JETTY_HOST/c\JETTY_HOST=127.0.0.1' /etc/default/jetty8
			sed -i '/JETTY_PORT/c\JETTY_PORT=8983' /etc/default/jetty8
			;;
		clamav)
			usermod -a -G vmail clamav 2> /dev/null
			service clamav-freshclam stop > /dev/null 2>&1
			killall freshclam 2> /dev/null
			rm -f /var/lib/clamav/* 2> /dev/null
			sed -i '/DatabaseMirror/d' /etc/clamav/freshclam.conf
			sed -i '/MaxFileSize/c\MaxFileSize 10240M' /etc/clamav/clamd.conf
			sed -i '/StreamMaxLength/c\StreamMaxLength 10240M' /etc/clamav/clamd.conf
			echo "DatabaseMirror clamav.netcologne.de
DatabaseMirror clamav.internet24.eu
DatabaseMirror clamav.inode.at" >> /etc/clamav/freshclam.conf
			if [[ -f /etc/apparmor.d/usr.sbin.clamd || -f /etc/apparmor.d/local/usr.sbin.clamd ]]; then
				rm /etc/apparmor.d/usr.sbin.clamd > /dev/null 2>&1
				rm /etc/apparmor.d/local/usr.sbin.clamd > /dev/null 2>&1
				service apparmor restart > /dev/null 2>&1
			fi
			install -m 755 clamav/clamav-unofficial-sigs.sh /usr/local/bin/clamav-unofficial-sigs.sh
			cp -f clamav/clamav-unofficial-sigs.conf /etc/clamav-unofficial-sigs.conf
			cp -f clamav/clamav-unofficial-sigs.8 /usr/share/man/man8/clamav-unofficial-sigs.8
			cp -f clamav/clamav-unofficial-sigs-cron /etc/cron.d/clamav-unofficial-sigs-cron
			cp -f clamav/clamav-unofficial-sigs-logrotate /etc/logrotate.d/clamav-unofficial-sigs-logrotate
			mkdir -p /var/log/clamav-unofficial-sigs 2> /dev/null
			sed -i '/MaxFileSize/c\MaxFileSize 10M' /etc/clamav/clamd.conf
			sed -i '/StreamMaxLength/c\StreamMaxLength 10M' /etc/clamav/clamd.conf
			freshclam 2> /dev/null
			;;
		opendkim)
			echo 'SOCKET="inet:10040@localhost"' > /etc/default/opendkim
			mkdir -p /etc/opendkim/{keyfiles,dnstxt} 2> /dev/null
			touch /etc/opendkim/{KeyTable,SigningTable}
			install -m 644 opendkim/conf/opendkim.conf /etc/opendkim.conf
			;;
		spamassassin)
			cp spamassassin/conf/local.cf /etc/spamassassin/local.cf
			if [[ ! -f /etc/spamassassin/local.cf.include ]]; then
				cp spamassassin/conf/local.cf.include /etc/spamassassin/local.cf.include
			fi
			sed -i '/^OPTIONS=/s/=.*/="--create-prefs --max-children 5 --helper-home-dir --username debian-spamd --socketpath \/var\/run\/spamd.sock --socketowner debian-spamd --socketgroup debian-spamd"/' /etc/default/spamassassin
			sed -i '/^CRON=/s/=.*/="1"/' /etc/default/spamassassin
			sed -i '/^ENABLED=/s/=.*/="1"/' /etc/default/spamassassin
			# Thanks to mf3hd@GitHub
			[[ -z $(grep RANDOM_DELAY /etc/crontab) ]] && sed -i '/SHELL/a RANDOM_DELAY=30' /etc/crontab
			install -m 755 spamassassin/conf/spamlearn /etc/cron.daily/spamlearn
			install -m 755 spamassassin/conf/spamassassin_heinlein /etc/cron.daily/spamassassin_heinlein
			# Thanks to mf3hd@GitHub, again!
			chmod g+s /etc/spamassassin
			chown -R debian-spamd: /etc/spamassassin
			razor-admin -create -home /etc/razor -conf=/etc/razor/razor-agent.conf
			razor-admin -discover -home /etc/razor
			razor-admin -register -home /etc/razor
			su debian-spamd -c "pyzor --homedir /etc/mail/spamassassin/.pyzor discover 2> /dev/null"
			su debian-spamd -c "sa-update 2> /dev/null"
			if [[ -f /lib/systemd/systemd ]]; then
				systemctl enable spamassassin
			fi
			;;
		webserver)
			mkdir -p /var/www/ 2> /dev/null
			rm /etc/apache2/sites-enabled/{mailcow*,000-0-mailcow,000-0-fufix,000-0-mailcow.conf} 2>/dev/null
			cp webserver/apache2/conf/sites-available/mailcow.conf /etc/apache2/sites-available/
			ln -s /etc/apache2/sites-available/mailcow.conf /etc/apache2/sites-enabled/000-0-mailcow.conf 2>/dev/null
			sed -i "s/MAILCOW_HOST/${sys_hostname}/g" /etc/apache2/sites-available/mailcow.conf
			sed -i "s/MAILCOW_DOMAIN/${sys_domain}/g" /etc/apache2/sites-available/mailcow.conf
			a2enmod rewrite ssl headers cgi proxy proxy_http > /dev/null 2>&1
			mkdir /var/lib/php5/sessions 2> /dev/null
			cp -R webserver/htdocs/mail /var/www/
			find /var/www/mail -type d -exec chmod 755 {} \;
			find /var/www/mail -type f -exec chmod 644 {} \;
			touch /var/mailcow/mailbox_backup_env
			echo none > /var/mailcow/log/pflogsumm.log
			sed -i "s/my_dbhost/${my_dbhost}/g" /var/www/mail/inc/vars.inc.php
			sed -i "s/my_mailcowpass/${my_mailcowpass}/g" /var/www/mail/inc/vars.inc.php
			sed -i "s/my_mailcowuser/${my_mailcowuser}/g" /var/www/mail/inc/vars.inc.php
			sed -i "s/my_mailcowdb/${my_mailcowdb}/g" /var/www/mail/inc/vars.inc.php
			chown -R www-data: /var/www/{.,mail} /var/lib/php5/sessions /var/mailcow/mailbox_backup_env
			mysql --host ${my_dbhost} -u root -p${my_rootpw} ${my_mailcowdb} < webserver/htdocs/init.sql
			if [[ $(mysql --host ${my_dbhost} -u root -p${my_rootpw} ${my_mailcowdb} -s -N -e "SELECT * FROM admin;" | wc -l) -lt 1 ]]; then
				mailcow_admin_pass_hashed=$(doveadm pw -s SSHA256 -p $mailcow_admin_pass)
				mysql --host ${my_dbhost} -u root -p${my_rootpw} ${my_mailcowdb} -e "INSERT INTO admin VALUES ('$mailcow_admin_user','$mailcow_admin_pass_hashed',1,now(),now(),1);"
				mysql --host ${my_dbhost} -u root -p${my_rootpw} ${my_mailcowdb} -e "INSERT INTO domain_admins (username, domain, created, active) VALUES ('$mailcow_admin_user', 'ALL', now(), '1');"
			else
				echo "$(textb [INFO]) - At least one administrator exists, will not create another mailcow administrator"
			fi
			;;
		sogo)
			if [[ -z $(mysql --host ${my_dbhost} -u root -p${my_rootpw} ${my_mailcowdb} -e "SHOW TABLES LIKE 'sogo_view'" -N -B) ]]; then
				mysql --host ${my_dbhost} -u root -p${my_rootpw} ${my_mailcowdb} -e "CREATE VIEW sogo_view (c_uid, c_name, c_password, c_cn, mail, home) AS SELECT username, username, password, CONVERT(name USING latin1), username, CONCAT('/var/vmail/', maildir) FROM mailbox WHERE active=1;" -N -B
			fi
			sudo -u sogo bash -c "
			defaults write sogod SOGoUserSources '({type = sql;id = directory;viewURL = mysql://${my_mailcowuser}:${my_mailcowpass}@${my_dbhost}:3306/${my_mailcowdb}/sogo_view;canAuthenticate = YES;isAddressBook = YES;displayName = \"Global Address Book\";userPasswordAlgorithm = ssha256;})'
			defaults write sogod SOGoProfileURL 'mysql://${my_mailcowuser}:${my_mailcowpass}@${my_dbhost}:3306/${my_mailcowdb}/sogo_user_profile'
			defaults write sogod OCSFolderInfoURL 'mysql://${my_mailcowuser}:${my_mailcowpass}@${my_dbhost}:3306/${my_mailcowdb}/sogo_folder_info'
			defaults write sogod OCSSessionsFolderURL 'mysql://${my_mailcowuser}:${my_mailcowpass}@${my_dbhost}:3306/${my_mailcowdb}/sogo_sessions_folder'
			defaults write sogod SOGoPageTitle '${sys_hostname}.${sys_domain}';
			defaults write sogod SOGoForwardEnabled YES;
			defaults write sogod SOGoMailAuxiliaryUserAccountsEnabled YES;
			defaults write sogod SOGoTimeZone '${sys_timezone}';
			defaults write sogod SOGoMailDomain '${sys_domain}';
			defaults write sogod SOGoAppointmentSendEMailNotifications YES;
			defaults write sogod SOGoSieveScriptsEnabled YES;
			defaults write sogod SOGoSieveServer 'sieve://${sys_hostname}.${sys_domain}:4190';
			defaults write sogod SOGoVacationEnabled YES;
			defaults write sogod SOGoDraftsFolderName Drafts;
			defaults write sogod SOGoSentFolderName Sent;
			defaults write sogod SOGoTrashFolderName Trash;
			defaults write sogod SOGoIMAPServer '${sys_hostname}.${sys_domain}';
			defaults write sogod SOGoSMTPServer 127.0.0.1:588;
			defaults write sogod SOGoMailingMechanism smtp;
			defaults write sogod SOGoMailCustomFromEnabled YES;
			# Temp. set to NO, doveadm verifies hashes by {HASHTYPE}HASH, SOGo only adds the hash but is fine the other way round, weird.
			defaults write sogod SOGoPasswordChangeEnabled NO;
			defaults write sogod SOGoAppointmentSendEMailNotifications YES;
			defaults write sogod SOGoACLsSendEMailNotifications YES;
			defaults write sogod SOGoFoldersSendEMailNotifications YES;
			defaults write sogod SOGoLanguage English;
			defaults write sogod SOGoMemcachedHost '127.0.0.1';
			defaults write sogod SOGoMaximumPingInterval 300;
			defaults write sogod SOGoMaximumSyncInterval 3;
			defaults write sogod SOGoInternalSyncInterval 3;"
			# ~1 for 10 users, more when AS is enabled
			sed -i '/PREFORK/c\PREFORK=15' /etc/default/sogo
			;;
		rsyslogd)
			if [[ -d /etc/rsyslog.d ]]; then
				rm /etc/rsyslog.d/10-fufix > /dev/null 2>&1
				cp rsyslog/conf/10-mailcow /etc/rsyslog.d/
				service rsyslog restart > /dev/null 2>&1
				postlog -p warn dummy > /dev/null 2>&1
				postlog -p info dummy > /dev/null 2>&1
				postlog -p err dummy > /dev/null 2>&1
			fi
			;;
		fail2ban)
			if [[ ! -z $(dpkg --get-selections | grep -E "^fail2ban.*install$") ]]; then
				echo "$(textb [INFO]) - Fail2ban was installed from repository, skipping installation..."
			else
				tar xf fail2ban/inst/${fail2ban_version}.tar -C fail2ban/inst/
				rm -rf /etc/fail2ban/ 2> /dev/null
				(cd fail2ban/inst/${fail2ban_version} ; python setup.py -q install 2> /dev/null)
				mkdir -p /var/run/fail2ban
				if [[ -f /lib/systemd/systemd ]]; then
					cp fail2ban/conf/fail2ban.service /etc/systemd/system/fail2ban.service
					systemctl disable fail2ban
					[[ -f /lib/systemd/system/fail2ban.service ]] && rm /lib/systemd/system/fail2ban.service
					systemctl daemon-reload
					systemctl enable fail2ban
				else
					install -m 755 fail2ban/conf/fail2ban.init /etc/init.d/fail2ban
					update-rc.d fail2ban defaults
				fi
				if [[ ! -f /var/log/mail.warn ]]; then
					touch /var/log/mail.warn
				fi
				if [[ ! -f /etc/fail2ban/jail.local ]]; then
					cp fail2ban/conf/jail.local /etc/fail2ban/jail.local
				fi
				cp fail2ban/conf/jail.d/*.conf /etc/fail2ban/jail.d/
				rm -rf fail2ban/inst/${fail2ban_version}
				[[ -z $(grep fail2ban /etc/rc.local) ]] && sed -i '/^exit 0/i\test -d /var/run/fail2ban || install -m 755 -d /var/run/fail2ban/' /etc/rc.local
				mkdir /var/run/fail2ban/ 2> /dev/null
			fi
			;;
		restartservices)
			[[ -f /lib/systemd/systemd ]] && echo "$(textb [INFO]) - Restarting services, this may take a few seconds..."
			for var in jetty8 fail2ban rsyslog apache2 spamassassin fuglu dovecot postfix opendkim clamav-daemon sogo
			do
				service $var stop
				sleep 1.5
				service $var start
			done
			;;
	esac
}
upgradetask() {
	if [[ ! -f /etc/mailcow_version && ! -f /etc/fufix_version ]]; then
		echo "$(redb [ERR]) - mailcow is not installed"
		exit 1
	fi
	if [[ -z $(cat /etc/{fufix_version,mailcow_version} 2> /dev/null | grep -E "0.9|0.10|0.11|0.12|0.13|0.14") ]]; then
		echo "$(redb [ERR]) - Upgrade not supported"
		exit 1
	fi
	echo "$(textb [INFO]) - Checking for upgrade prerequisites and collecting system information..."
	if [[ -z $(which lsb_release) ]]; then
		apt-get -y update > /dev/null ; apt-get -y install lsb-release > /dev/null 2>&1
	fi
	[[ -z ${sys_hostname} ]] && sys_hostname=$(hostname -s)
	[[ -z ${sys_domain} ]] && sys_domain=$(hostname -d)
	sys_timezone=$(cat /etc/timezone)
	timestamp=$(date +%Y%m%d_%H%M%S)
	readconf=( $(php -f misc/readconf.php) )
	my_dbhost=${readconf[0]}
	my_mailcowuser=${readconf[1]}
	my_mailcowpass=${readconf[2]}
	my_mailcowdb=${readconf[3]}
	echo "$(pinkb [NOTICE]) - mailcow needs your SQL root password to perform higher privilege level tasks"
        read -p "Please enter your SQL root user password: " my_rootpw
	while [[ $(mysql --host ${my_dbhost} -u root -p${my_rootpw} -e ""; echo $?) -ne 0 ]]; do
		read -p "Please enter your SQL root user password: " my_rootpw
	done
	[[ -z ${my_dbhost} ]] && my_dbhost="localhost"
	for var in sys_hostname sys_domain sys_timezone my_dbhost my_mailcowdb my_mailcowuser my_mailcowpass
	do
		if [[ -z ${!var} ]]; then
			echo "$(redb [ERR]) - Could not gather required information: \"${var}\" empty, upgrade failed..."
			echo
			exit 1
		fi
	done
	echo -e "\nThe following configuration was detected:"
	echo "
$(textb "Hostname")               ${sys_hostname}
$(textb "Domain")                 ${sys_domain}
$(textb "FQDN")                   ${sys_hostname}.${sys_domain}
$(textb "Timezone")               ${sys_timezone}
$(textb "mailcow MySQL")          ${my_mailcowuser}:${my_mailcowpass}@${my_dbhost}/${my_mailcowdb}
$(textb "Web root")               https://${sys_hostname}.${sys_domain}

--------------------------------------------------------
THIS UPGRADE WILL RESET SOME OF YOUR CONFIGURATION FILES
--------------------------------------------------------
A backup will be stored in ./before_upgrade_$timestamp
--------------------------------------------------------
"
	if [[ ${inst_confirm_proceed} == "yes" ]]; then
		echo "$(pinkb [NOTICE]) - You can overwrite the detected hostname and domain by calling the installer with -H hostname and -D example.org"
		read -p "Press ENTER to continue or CTRL-C to cancel the upgrade process"
	fi
	echo -en "Creating backups in ./before_upgrade_$timestamp... \t"
	mkdir before_upgrade_$timestamp
	cp -R /var/www/mail/ before_upgrade_$timestamp/mail_wwwroot
	mysqldump -u ${my_mailcowuser} -p${my_mailcowpass} ${my_mailcowdb} > backup_mailcow_db.sql 2>/dev/null
	cp -R /etc/{postfix,dovecot,spamassassin,fail2ban,apache2,fuglu,mysql,php5,clamav} before_upgrade_$timestamp/
	echo -e "$(greenb "[OK]")"
	echo -en "\nStopping services, this may take a few seconds... \t\t"
	for var in fail2ban rsyslog apache2 spamassassin fuglu dovecot postfix opendkim clamav-daemon stop
	do
		service $var stop > /dev/null 2>&1
	done
	echo -e "$(greenb "[OK]")"
	if [[ ! -z $(openssl x509 -issuer -in /etc/ssl/mail/mail.crt | grep ${sys_hostname}.${sys_domain} ) ]]; then
		echo "$(textb [INFO]) - Update CA certificate store (self-signed only)..."
		cp /etc/ssl/mail/mail.crt /usr/local/share/ca-certificates/
		update-ca-certificates
	fi
	if [[ ! -f /etc/ssl/mail/dhparams.pem ]]; then
		echo "$(textb [INFO]) - Generating 2048 bit DH parameters, this may take a while, please wait..."
		openssl dhparam -out /etc/ssl/mail/dhparams.pem 2048 2> /dev/null
	fi

	echo "Starting task \"Package installation\"..."
	installtask installpackages
	returnwait "Package installation" "Postfix configuration"

	installtask postfix
	returnwait "Postfix configuration" "Dovecot configuration"

	installtask dovecot
	returnwait "Dovecot configuration" "FuGlu configuration"

	installtask fuglu
	returnwait "FuGlu configuration" "ClamAV configuration"

	installtask clamav
	returnwait "ClamAV configuration" "Spamassassin configuration"

	installtask spamassassin
	returnwait "Spamassassin configuration" "Webserver configuration"

	rm -rf /var/lib/php5/sessions/*
	mkdir -p /var/mailcow/log
	mv /var/www/MAILBOX_BACKUP /var/mailcow/mailbox_backup_env 2> /dev/null
	mv /var/www/PFLOG /var/mailcow/log/pflogsumm.log 2> /dev/null

	installtask webserver
	returnwait "Webserver configuration" "SOGo configuration"

	installtask sogo
	returnwait "SOGo configuration" "OpenDKIM configuration"

	installtask opendkim
	returnwait "OpenDKIM configuration" "Rsyslogd configuration"

	installtask rsyslogd
	returnwait "Rsyslogd configuration" "Fail2ban configuration"

	installtask fail2ban
	# restore user configuration (*.local)
	cp before_upgrade_$timestamp/fail2ban/*.local /etc/fail2ban/
	cp before_upgrade_$timestamp/fail2ban/action.d/*.local /etc/fail2ban/action.d/ 2> /dev/null
	cp before_upgrade_$timestamp/fail2ban/filter.d/*.local /etc/fail2ban/filter.d/ 2> /dev/null
	cp before_upgrade_$timestamp/fail2ban/jail.d/*.local /etc/fail2ban/jail.d/ 2> /dev/null
	returnwait "Fail2ban configuration" "Restarting services"

	installtask restartservices
	returnwait "Restarting services" "Finish upgrade"
	echo Done.
	echo
	echo "\"installer.log\" file updated."
	return 0
}
