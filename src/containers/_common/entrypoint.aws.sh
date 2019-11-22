#!/bin/bash
# Universal entrypoint script for containerized tooling for use with AWS Batch
# that handles data staging of predefined inputs and outputs.
#
# Environment Variables
#   JOB_AWS_CLI_PATH
#       Required if staging data from S3
#       Default: /opt/miniconda/bin
#       Path to add to the PATH environment variable so that the AWS CLI can be
#       located.  Use this if bindmounting the AWS CLI from the host and it is
#       packaged in a self-contained way (e.g. not needing OS/distribution 
#       specific shared libraries).  The AWS CLI installed with `conda` is
#       sufficiently self-contained.  Using a standard python virtualenv does
#       not work.
# 
#   JOB_INPUT_PATH
#       Optional
#       Default: container CWD or WORKDIR
#       Path within container where input files will be staged.
#
#   JOB_OUTPUT_PATH
#       Optional
#       Default: container CWD or WORKDIR
#       Path within container where output files are expected.
#
#   JOB_DATA_ISOLATION
#       Optional
#       Default: null
#       Set to 1 if container will need to use an isolated data space - e.g.
#       it will use a volume mounted from the host for scratch
#
#   JOB_INPUTS
#       Optional
#       Default: null
#       A space delimited list of s3 object urls - e.g.:
#           s3://{prefix1}/{key_pattern1} [s3://{prefix2}/{key_pattern2} [...]]
#       for files that the job will use as inputs
#
#   JOB_OUTPUTS
#       Optional
#       Default: null
#       A space delimited list of files - e.g.:
#           file1 [file2 [...]]
#       that the job generates that will be retained - i.e. transferred back to S3
#
#   JOB_OUTPUT_PREFIX
#       Required if JOB_OUTPUTS need to be stored on S3
#       Default: null
#       S3 location (e.g. s3://bucket/prefix) were job outputs will be stored

set -e

# Command is specified in the JobSubmission container overrides.
# gives the user flexibility to specify tooling options as needed.
#
# Note that AWS Batch has an implicit 8kb limit on the amount of data allowed in
# container overrides, which includes environment variable data.
COMMAND="$@"

DEFAULT_AWS_CLI_PATH=/opt/miniconda/bin
AWS_CLI_PATH=${JOB_AWS_CLI_PATH:-$DEFAULT_AWS_CLI_PATH}
PATH=$PATH:$AWS_CLI_PATH

DEFAULT_INPUT_PATH=.
DEFAULT_OUTPUT_PATH=.

INPUT_PATH=${JOB_INPUT_PATH:-$DEFAULT_INPUT_PATH}
OUTPUT_PATH=${JOB_OUTPUT_PATH:-$DEFAULT_OUTPUT_PATH}

if [[ $JOB_DATA_ISOLATION && $JOB_DATA_ISOLATION == 1 ]]; then
    ## AWS Batch places multiple jobs on an instance
    ## To avoid file path clobbering if using a host mounted scratch use the JobID 
    ## and JobAttempt to create a unique path
    
    if [[ $AWS_BATCH_JOB_ID ]]; then
        GUID="$AWS_BATCH_JOB_ID/$AWS_BATCH_JOB_ATTEMPT"
    else
        GUID=`date | md5sum | cut -d " " -f 1`
    fi

    INPUT_PATH=$INPUT_PATH/$GUID
    OUTPUT_PATH=$OUTPUT_PATH/$GUID
fi

mkdir -p $INPUT_PATH $OUTPUT_PATH

function stage_in() (
    # loops over list of inputs (patterns allowed) which are a space delimited list
    # of s3 urls:
    #   s3://{prefix1}/{key_pattern1} [s3://{prefix2}/{key_pattern2} [...]]
    # uses the AWS CLI to download objects

    # `noglob` option is needed so that patterns are not expanded against the 
    # local filesystem. this setting is local to the function
    set -o noglob

    for item in $@; do
        if [[ $item =~ ^s3:// ]]; then
            local item_key=`basename $item`
            local item_prefix=`dirname $item`

            echo "[input] remote: $item ==> $INPUT_PATH/$item_key"
            
            aws s3 cp \
                --no-progress \
                --recursive \
                --exclude "*" \
                --include "${item_key}" \
                ${item_prefix} $INPUT_PATH

        else
            echo "[input] local: $item"

        fi
    done
)

function stage_out() (
    # loops over list of outputs which are a space delimited list of filenames:
    #   file1 [file2 [...]]
    # uses the AWS CLI to upload objects

    for item in ${items[@]}; do
        if [ ! -f $item ]; then
            # If an expected output is not found it is generally considered an
            # error.  To suppress this error when using glob expansion you can 
            # set the `nullglob` option (`shopt -s nullglob`)
            echo "[output] ERROR: $item does not exist"
            exit 1
        else
            if [[ $JOB_OUTPUT_PREFIX && $JOB_OUTPUT_PREFIX =~ ^s3:// ]]; then
                local item_key=`basename $item`

                echo "[output] remote: $OUTPUT_PATH/$item ==> $prefix/${item_key}"

                aws s3 cp \
                    --no-progress \
                    $OUTPUT_PATH/$item $prefix/${item_key}

            elif [[ $JOB_OUTPUT_PREFIX && ! $JOB_OUTPUT_PREFIX =~ ^s3:// ]]; then
                echo "[output] ERROR: unsupported remote output destination $JOB_OUTPUT_PREFIX"

            else
                echo "[output] local: $item"

            fi
        fi
    done
)

stage_in $JOB_INPUTS

# command, for example:
# bwa mem -t 16 -p \
#     $INPUT_PATH/${REFERENCE_NAME}.fasta \
#     $INPUT_PATH/${SAMPLE_ID}_*1*.fastq.gz \
#     > $OUTPUT_PATH/${SAMPLE_ID}.sam
$COMMAND


stage_out $JOB_OUTPUTS

