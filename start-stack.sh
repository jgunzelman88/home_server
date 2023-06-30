STATUS=true
SERVICE="$1"
CONFIG="$2"
SlEEP_INT=3600
#Start docker stack
sudo docker stack deploy -c $CONFIG $SERVICE
#check status periodically
while STATUS 
do 
    status_output="$(sudo docker stack ps -f desired-state=running $SERVICE)"
    if ["$status_output" != "nothing found in stack: $SERVICE"]; then
        STATUs=false
    fi
done