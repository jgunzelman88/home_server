STATUS=true
SERVICE="$1"
CONFIG="$2"
#Start docker stack
sudo docker stack deploy -c $CONFIG $SERVICE
#check status periodically
while "$STATUS" 
do 
    status_output="$(sudo docker stack ps -f desired-state=running $SERVICE)"
    if ["$status_output" != "nothing found in stack: $SERVICE"]; then
        STATUS=false 
    fi
    sleep 3600
done