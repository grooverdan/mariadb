#!/bin/sh

set -xeuvo pipefail

die()
{
	echo $@ >2
	exit 1
}

runandwait()
{
	n=$1
	# recautionary kill
	podman kill "$n" 2>&1 > /dev/null || :
	shift
	podman run --name "$n" --rm  --publish 3306 "$@"
	port=$(podman port "$n" 3306)
	port=${port#*:}
	waiting=6
       	while [ $waiting -gt 0 ]
       	do
	       waiting=$(( $waiting - 1 ))
	       sleep 1
	       nc localhost $port < /dev/null | read -n 50 startproto && break
	       #echo > /dev/tcp/localhost/$port && break
	       #podman logs "$n"
        done

        #podman logs --follow "$n" | grep -m 1 'port: 3306'
	#podman exec "$n" sh -c 'c=5; while [ $c -gt 0 ] && [ ! -S /run/mysqld/mysqld.sock ]; do echo waiting $c; c=$(( $c - 1 )); sleep 1; done; [ -S /run/mysqld/mysqld.sock ] || return 1'
}


# Failure - none of MYSQL_ALLOW_EMPTY_PASSWORD, MYSQL_RANDOM_ROOT_PASSWORD, MYSQL_ROOT_PASSWORD
podman run --rm --name m_noargs mariadb && die "should fail with 'Database is uninitialized and password option is not specified'"

# Defaults to clean environment
runandwait m_envtest -d  -e MYSQL_ALLOW_EMPTY_PASSWORD=1  mariadb
podman exec -t m_envtest  mysql -u root -e 'show databases'

othertables=$(podman exec -t m_envtest  mysql -u root --skip-column-names -Be "select group_concat(SCHEMA_NAME) from information_schema.SCHEMATA where SCHEMA_NAME not in ('mysql', 'information_schema', 'performance_schema')")

[ "${othertables}" != $'NULL\r' ] && die "unexpected table(s) $othertables"
otherusers=$(podman exec -t m_envtest  mysql -u root --skip-column-names -Be "select user,host from mysql.user where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'))")

[ "$otherusers" != '' ] && die "unexpected users $otherusers"
podman kill m_envtest

# MYSQL_ROOT_PASSWORD

runandwait m_rootpass -d  -e MYSQL_ROOT_PASSWORD=examplepass  mariadb
podman exec -t m_rootpass  mysql -u root -pexamplepass -e 'select current_user()'
podman exec -t m_rootpass  mysql -u root -pwrongpass -e 'select current_user()' || echo 'expected failure' 
podman kill m_rootpass

# MYSQL_ALLOW_EMPTY_PASSWORD

runandwait m_emptyrootpass -d  -e MYSQL_ALLOW_EMPTY_PASSWORD=1  mariadb
podman exec -t m_emptyrootpass  mysql -u root -e 'select current_user()'
podman kill m_emptyrootpass
podman exec -t m_emptyrootpass  mysql -u root -pexamplepass -e 'select current_user()' || echo 'expected failure'

# MYSQL_ALLOW_EMPTY_PASSWORD Implementation is non-empty value so this should fail
podman run  --rm  --name m_emptyrootpass -d  -e MYSQL_ALLOW_EMPTY_PASSWORD  mariadb || echo 'expected failure'


# MYSQL_ROOT_PASSWORD
runandwait m_rndrootpass -d  -e MYSQL_RANDOM_ROOT_PASSWORD=1  mariadb
pass=$(podman logs m_rndrootpass | grep 'GENERATED ROOT PASSWORD' 2>&1)
# trim up until passwod
pass=${pass##* } 
podman exec -t m_rndrootpass  mysql -u root -p"${pass}" -e 'select current_user()'
podman kill m_rndrootpass

runandwait m_rndrootpass -d  -e MYSQL_RANDOM_ROOT_PASSWORD=1  mariadb
newpass=$(podman logs m_rndrootpass | grep 'GENERATED ROOT PASSWORD' 2>&1)
# trim up until passwod
newpass=${newpass##* } 
podman kill m_rndrootpass

[ "$pass" = "$newpass" ] && die "highly improbable - two consequitive passwords are the same" 

# MYSQL_ROOT_HOST
runandwait m_roothost -d -e  MYSQL_ALLOW_EMPTY_PASSWORD=1  -e MYSQL_ROOT_HOST=apple  mariadb
ru=$(podman exec -t m_roothost  mysql  --skip-column-names -B -u root -e 'select user,host from mysql.user where host="apple"')
[ "${ru}" = '' ] && die 'root@apple not created'
podman kill m_roothost


# MYSQL_INITDB_SKIP_TZINFO=''

runandwait m_with_tzinit -d -e MYSQL_INITDB_SKIP_TZINFO= -e MYSQL_ALLOW_EMPTY_PASSWORD=1  mariadb
tzcount=$(podman exec -t m_with_tzinit  mysql  --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = $'0\r' ] && die "should exist timezones"
podman kill m_with_tzinit

# MYSQL_INITDB_SKIP_TZINFO=1

runandwait m_without_tzinit -d -e MYSQL_INITDB_SKIP_TZINFO=1 -e MYSQL_ALLOW_EMPTY_PASSWORD=1  mariadb
tzcount=$(podman exec -t m_without_tzinit  mysql --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = $'0\r' ] || die "timezones shouldn't be loaded - found ${tzcount}"
podman kill m_without_tzinit

# Secrets _FILE vars
secretdir=$(mktemp -d)
ddir=$(mktemp -d)
echo bob > "$secretdir"/pass
echo pluto > "$secretdir"/host
echo titan > "$secretdir"/db
echo ron > "$secretdir"/u
echo scappers > $secretdir/p
podman unshare chown root: -R "$secretdir"
podman unshare chown 999:999 -R "$ddir"
# bug because of rootless - root+mysql need to read it - fixable in entrypoint
#!podman unshare chmod go+rwX -R "$ddir"

#!       	-v "$ddir":/var/lib/mysql \
runandwait m_secrets -d \
       	-v "$secretdir":/run/secrets:Z \
	-e MYSQL_ROOT_PASSWORD_FILE=/run/secrets/pass \
	-e MYSQL_ROOT_HOST_FILE=/run/secrets/host \
	-e MYSQL_DATABASE_FILE=/run/secrets/db \
	-e MYSQL_USER_FILE=/run/secrets/u \
	-e MYSQL_PASSWORD_FILE=/run/secrets/p \
	mariadb
host=$(podman exec -t m_secrets mysql  --skip-column-names -B -u root -pbob -e 'select host from mysql.user where user="root" and host="pluto"' titan)
[ "${host}" != $'pluto\r' ] && die 'root@pluto not created'
creation=$(podman exec -t m_secrets mysql --skip-column-names -B -u ron -pscappers -P 3306 --protocol tcp titan -e "CREATE TABLE landing (i INT)")
[ "${creation}" = '' ] || die 'creation error'

podman kill m_secrets
podman unshare chown root: -R "$ddir"
rm -rf "${secretdir}"

#!# restart on prev volumne
#!runandwait m_reuse -d \
#!       	-v "$ddir":/var/lib/mysql \
#!	mariadb
#!persistent=$(podman exec -t m_reuse mysql --skip-column-names -B -u ron -pscappers -P 3306 --protocol tcp titan -e "insert into landing values (32),(42),(48)")
#![ "${persistent}" = '' ] || die 'reuse error error'
#!podman kill m_reuse
rm -rf "${ddir}"

initdb=$(mktemp -d)
cp -a initdb.d/* "${initdb}"
gzip "${initdb}"/*gz*
xz "${initdb}"/*xz*
podman unshare chown 999:999 -R "$initdb"
runandwait m_init -d \
        -v "${initdb}":/docker-entrypoint-initdb.d:Z \
	-e MYSQL_ROOT_PASSWORD=ssh \
	-e MYSQL_DATABASE=titan \
	-e MYSQL_USER=ron \
	-e MYSQL_PASSWORD=scappers \
	mariadb
init_sum=$(podman exec -t m_init mysql --skip-column-names -B -u ron -pscappers -P 3306 -h 127.0.0.1  --protocol tcp titan -e "select sum(i) from t1;")
[ "${init_sum}" = $'1860\r' ] || (podman logs m_init; die 'initialization order error')
podman kill m_init
podman unshare chown root: -R "$initdb"
rm -rf "${initdb}"


exit 0

# Prefer MariaDB names
runandwait m_rootpass -d  -e MARIADB_ROOT_PASSWORD=examplepass -e MYSQL_ROOT_PASSWORD=mysqlexamplepass  mariadb
podman exec -t m_rootpass  mysql -u root -pexamplepass -e 'select current_user()'
podman exec -t m_rootpass  mysql -u root -pwrongpass -e 'select current_user()' || echo 'expected failure' 
podman kill m_rootpass

#TODO - copy above tests with s/MYSQL_/MARIADB_/g
