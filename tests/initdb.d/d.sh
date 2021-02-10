#!/bin/false source me, I have no execute perms
mysql -u "${MARIADB_USER:-$MYSQL_USER}" -p"${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" \
	-e 'update t1 set i=i*3' \
	"${MARIADB_DATABASE:-$MYSQL_DATABASE}"
