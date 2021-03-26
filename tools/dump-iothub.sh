#!/bin/bash

# -------------------------------------------------------------------------------

usage(){
    echo '
Usage: '"$0"' 
    --resourcegroup, -g        Resource group in which the iot hub 
                               resides.
    --hub, -n                  The iot hub to get edge information from. 
    --output, -o               The output folder to use. 
    --subscription, -s         Subscription where the resource group or 
                               iot hub was created.  If not set uses
                               the default subscription for the account.
    --help                     Shows this help.
'
    exit 1
}

iothubname=
subscription=
resourcegroup=
output=

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --hub)                 iothubname="$2" ;;
        --resourcegroup)       resourcegroup="$2" ;;
        --subscription)        subscription="$2" ;;
        --output)              output="$2" ;;
        -n)                    iothubname="$2" ;;
        -g)                    resourcegroup="$2" ;;
        -s)                    subscription="$2" ;;
        -o)                    output="$2" ;;
        --help)                usage ;;
    esac
    shift
done

if [[ -n "$output" ]] ; then
    mkdir -p $output
    cd $output
fi
output=$PWD

if [[ -n "$subscription" ]] ; then
    az account set --subscription $subscription
fi

if [[ -z "$iothubname" ]] ; then
    if [[ -z "$resourcegroup" ]] ; then
        echo "Must provide name of iot hub or resourcegroup name!"
        usage
    fi
    iothubname=$(az iot hub list -g $resourcegroup \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$iothubname" ]]; then
        echo "ERROR: Unable to determine iot hub name."
        echo "ERROR: Ensure one was created in resource group $resourcegroup."
        exit 1
    fi
fi

rm -rdf $iothubname
mkdir $iothubname
cd $iothubname
echo "Dumping deployments..."
if ! az iot edge deployment list -n $iothubname > deployments.json ; then
    echo "ERROR: Unable to get deployments from iot hub $iothubname."
    exit 1
fi
mkdir devices
cd devices
if ! devices=($(az iot hub device-identity list -n $iothubname \
    --query "[].deviceId" -o tsv | tr -d '\r')) ; then
    echo "ERROR: Unable to get edge devics from iot hub $iothubname."
    exit 1
fi
count=0
total=${#devices[@]}
start=`date +%s`
echo "Dumping $total device twins and related module twins..."
for deviceId in "${devices[@]}" ; do 
    if ! az iot hub device-twin show -n $iothubname -d $deviceId > $deviceId.json ; then
echo "ERROR: Unable to get device twin of $deviceId on iot hub $iothubname."
        exit 1
    fi
    if ! modules=($(az iot hub module-identity list -n $iothubname -d $deviceId \
        --query "[].moduleId" -o tsv | tr -d '\r')) ; then
echo "ERROR: Unable to get modules on device $deviceId on iot hub $iothubname."
        exit 1
    fi
    if [[ ${#modules[@]} > 0 ]] ; then
        mkdir -p $deviceId/modules
        for moduleId in "${modules[@]}" ; do 
            if ! az iot hub module-twin show -n $iothubname -d $deviceId \
                -m $moduleId > $deviceId/modules/$moduleId.json ; then
echo "ERROR: Unable to get module twin $moduleId in $deviceId on iot hub $iothubname."
                exit 1
            fi
        done
    fi
    cur=`date +%s`
    count=$(( $count + 1 ))
    pd=$(( $count * 73 / $total ))
    runtime=$(( $cur-$start ))
    estremain=$(( ($runtime * $total / $count)-$runtime ))
    printf "\r%d.%d%% complete ($count of $total) - est %d:%0.2d remaining\e[K" \
        $(( $count*100/$total )) $(( ($count*1000/$total)%10)) \
            $(( $estremain/60 )) $(( $estremain%60 ))
done
printf "\ndone\n"
cd ..

# ...

cd $output
# tar the $iothubname folder and delete it.
cur=`date +%s`
rm -f $iothubname_$cur.tar.gz
tar -czvf $iothubname.tar.gz $iothubname
# rm -rdf $iothubname
