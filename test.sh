#!/bin/bash
#
# This is the InfluxDB test script.
# This script can run tests in different environments.
#
# Usage: ./test.sh <environment_index>
# Corresponding environments for environment_index:
#      0: normal 64bit tests
#      1: race enabled 64bit tests
#      2: normal 32bit tests
#      3: tsi build
#      count: print the number of test environments
#      *: to run all tests in parallel containers
#
# Logs from the test runs will be saved in OUTPUT_DIR, which defaults to ./test-logs
#

# Get dir of script and make it is our working directory.
DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
cd $DIR

ENVIRONMENT_INDEX=$1
# Set the default OUTPUT_DIR
OUTPUT_DIR=${OUTPUT_DIR-./test-logs}
# Set default parallelism
PARALLELISM=${PARALLELISM-1}
# Set default timeout
TIMEOUT=${TIMEOUT-1500s}

# Default to deleteing the container
DOCKER_RM=${DOCKER_RM-true}

# Update this value if you add a new test environment.
ENV_COUNT=4

# Default return code 0
rc=0

# Executes the given statement, and exits if the command returns a non-zero code.
function exit_if_fail {
    command=$@
    echo "Executing '$command'"
    $command
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "'$command' returned $rc."
        exit $rc
    fi
}

# Convert dockerfile name to valid docker image tag name.
function filename2imagename {
    echo ${1/Dockerfile/influxdb}
}

# Run a test in a docker container
# Usage: run_test_docker <Dockerfile> <env_name>
function run_test_docker {
    local dockerfile=$1
    local imagename=$(filename2imagename "$dockerfile")
    shift
    local name=$1
    shift
    local logfile="$OUTPUT_DIR/${name}.log"

    build_docker_image "$dockerfile" "$imagename"
    echo "Running test in docker $name with args $@"

    docker run \
         --rm=$DOCKER_RM \
         -v "$DIR:/root/go/src/github.com/influxdata/influxdb" \
         -e "INFLUXDB_DATA_ENGINE=$INFLUXDB_DATA_ENGINE" \
         -e "GORACE=$GORACE" \
         -e "GO_CHECKOUT=$GO_CHECKOUT" \
         -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
         -e "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
         "$imagename" \
         "--parallel=$PARALLELISM" \
         "--timeout=$TIMEOUT" \
         "$@" \
         2>&1 | tee "$logfile"
    return "${PIPESTATUS[0]}"

}

# Build the docker image defined by given dockerfile.
function build_docker_image {
    local dockerfile=$1
    local imagename=$2

    echo "Building docker image $imagename"
    exit_if_fail docker build --rm=$DOCKER_RM -f "$dockerfile" -t "$imagename" .
}


if [ ! -d "$OUTPUT_DIR" ]
then
    mkdir -p "$OUTPUT_DIR"
fi

# Run the tests.
case $ENVIRONMENT_INDEX in
    0)
        # 64 bit tests
        run_test_docker Dockerfile_build_ubuntu64 test_64bit --test --junit-report
        rc=$?
        ;;
    1)
        # 64 bit race tests
        GORACE="halt_on_error=1"
        run_test_docker Dockerfile_build_ubuntu64 test_64bit_race --test --junit-report --race
        rc=$?
        ;;
    2)
        # 32 bit tests
        run_test_docker Dockerfile_build_ubuntu32 test_32bit --test --junit-report --arch=i386
        rc=$?
        ;;
    3)
        # tsi
        INFLUXDB_DATA_INDEX_VERSION="tsi1"
        run_test_docker Dockerfile_build_ubuntu64 test_64bit --test --junit-report
        rc=$?
        ;;
    "count")
        echo $ENV_COUNT
        ;;
    *)
        echo "No individual test environment specified running tests for all $ENV_COUNT environments."
        # Run all test environments
        pids=()
        for t in $(seq 0 "$(($ENV_COUNT - 1))")
        do
            $0 $t 2>&1 > /dev/null &
            # add PID to list
            pids+=($!)
        done

        echo "Started all tests. Follow logs in ${OUTPUT_DIR}. Waiting..."

        # Wait for all tests to finish
        for pid in "${pids[@]}"
        do
            wait $pid
            rc=$(($? + $rc))
        done

        # Check if all tests passed
        if [ $rc -eq 0 ]
        then
            echo "All test have passed"
        else
            echo "Some tests failed check logs in $OUTPUT_DIR for results"
        fi
        ;;
esac

exit $rc
