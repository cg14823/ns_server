set +xe
# setup data quota
http --form POST localhost:9000/pools/default memoryQuota=500
# setup services
http --form POST localhost:9000/node/controller/setupServices services="kv,cbbs"
# setup admin user
http --form POST localhost:9000/settings/web username="Administrator" password="asdasd" port="SAME"
