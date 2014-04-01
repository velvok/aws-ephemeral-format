aws-ephemeral-format.sh
=======================

A script to format the ephermeral storage on Amazon EC2 instances, used mainly to add swap at boot time if its not already configured. 

## Example:

#### This will configure 8GB of swap on the ephemeral storage 

`sudo /home/ubuntu/scripts/aws-ephemeral-format.sh -t 82 -s 1024 -f swap`

Note: The script will not format the ephemeral storage if it alredady contains a partition table. 
