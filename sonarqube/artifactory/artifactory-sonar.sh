#!/bin/bash

# This script has to be invoked in the post-build phase
# of the pipeline. e.g 
#
# stage ("Post-Build") {
#     sh -c "export WAIT_FOR_ANALYSIS=true; ./artifactory-sonar.sh [true|false]"
#      ..... 
#  }
# 
#The pipeline environment is expected to set the following environment variables.
#
# 1. All CI specific default variables  
# 
# 2. ARTIFACTORY_URL, ARTIFACTORY_USER, ARTIFACTORY_APIKEY, ARTIFACTORY_REPO
#
# 3. WAIT_FOR_ANALYSIS to be set to "true" for synchronous operation, false
#    if no need to wait for the analysis to complete. If false, 
#    only SONAR_TASKSTATUS, SONAR_CETASKID environment variables will be
#    uploaded to build_info. SONAR_CETASKID has to be used to get all the 
#    other detais like ANALYSIS_ID and quality gate metrics and values
#    default = true
#
# 4. Invoke the script with argument "true" if we want to fail the build based on quality gate status.
#    Even if set to true, but quality gate information is not available
#   (if WAIT_FOR_ANALYSIS is set to false) then build cannot be failed.
#
# Also ensure that dependent command 'jq' is already installed and PATH
# environment variable configured to find jq, grep and awk.


# 
# Function waitForAnalysisToComplete
#
# Call this function after getting the taskid and server url from report-task.txt.
#
# This will use curl command to query the sonar server with the taskid to get the status
# If the status is PENDING or IN_PROGRESS, it will loop until it gets a SUCCESS
# or FAILED or CANCELLED status.
#
# Then it will get the analysisID from server and gets quality gate status.
# Using jq, it will get all the conditions and status and exports all them as environment
# variables.


waitForAnalysisToComplete() {

	while [ "$taskstatus" == "PENDING" -o "$taskstatus" == "IN_PROGRESS" ];
	do 
		echo Getting task status ...
		taskstatus=`curl ${srv}/api/ce/task?id=${ceTaskId} | jq -r .task.status`
		echo "$taskstatus"
	
		case "$taskstatus" in
			"PENDING")
				echo "Still Pending";
				sleep 10;
				continue;
				;;
			"IN_PROGRESS")
				echo "Still In Progress";
				sleep 10;
				continue;
				;;
			"FAILED")
				echo "Just Failed";
				break;
				;;
			"CANCELLED")
				echo "Cancelled";
				break;
				;;
			"SUCCESS")
				echo "Got success";
				analysisComplete=true;
				break;
				;;
			"*")
				echo "Unknown status : $taskstatus";
				break;
				;;
		esac	
	done


	if [ $analysisComplete == false ]; then
		echo "Analysis has not been completed..."
		echo "Cannot get quality gate information .."
	else
		
		aID=`curl ${srv}/api/ce/task?id=${ceTaskId} | jq .task.analysisId`
		
		# If output of curl is a long string, it gets write failed 23"
		# on macos. so output to file and read from file"
		qurlstr="curl ${srv}/api/qualitygates/project_status?analysisId=${aID} -o qgate.out"
		eval ${qurlstr}
		qgjson=`cat qgate.out`
		qgstatus=`echo $qgjson | jq -r .projectStatus.status`
		
		echo SONAR_ANLYSIS_ID = $aID
		echo "Quality Gate Status = $qgstatus"
		
		export SONAR_ANALYSIS_ID=${aID};
		export SONAR_QGATESTATUS=${qgstatus};
		
		qgconditions=`echo $qgjson | jq .projectStatus.conditions`
		clist=`echo $qgconditions | jq -r '.[] | "\(.metricKey) \(.status)"'`
		echo "All Conditions List"
		echo $clist
		# We can also set the conditions list as one env var if need be
		# but for now, we get each condition metricKey and its value and set
		# as an environment variable.
		expallconditions=`echo $qgconditions | jq -r '.[] | "export SONAR_\(.metricKey)=\(.status);"'`
		
		echo "Export Command List for all QG Conditions"
		echo $expallconditions

#
# If we want to jut set quality gate conditions that have error only, istead of all
# we can use the following
#		experrconditions=`echo $qgconditions | jq -r ' .[] | select (.status == "ERROR") | " export SONAR_\(.metricKey)=\(.status);" '`
#	
#		echo "Export Command List for ERROR QG Conditions Only"
#		echo $experrconditions
# 		echo "Executing Export Command List for ERROR QG Conditions Only"
#		eval $experrconditions
#
		
		# For now, we want to export all conditions of quality gate status
		echo "Executing Export Command List for all QG Conditions"
		eval $expallconditions
		
		/bin/rm -f qgate.out
	
	fi
}


setReportFile()
{

	# Approach to find the sonar report to obtain the task id
	#1. test .sonar/sonar-report.txt
	#2. else test .scannerwork/sonar-report.txt (SonarScannerCLI)
	#3. else test target/sonar/sonar-report.txt (Maven)
	#4. else find sonar-report.txt in all other sub-directories


	rptfile=
	if [ -f .sonar/report-task.txt ]; then
		rptfile=".sonar/report-task.txt"
	elif [ -f .scannerwork/report-task.txt ]; then
		rptfile=".scannerwork/report-task.txt"
	elif [ -f target/sonar/report-task.txt ]; then
		rptfile="target/sonar/report-task.txt"
	else 
		rptfile=`find . -name report-task.txt -type f -print | head -n 1 2>/dev/null`
	fi
}


setCiInfo()
{
	citype=

	# Based on CITYPE,we can generalize build_name and build_number
	# In general each ci has its own env vars for build_number.
	# build_name can be derived from a couple of other vars
	# like repo_owner-repo_name-branch_id or jobname

	if [ ! -z $CIRCLECI ]; then
		citype="CIRCLECI"
		CI_BUILD_NUM=${CIRCLE_BUILD_NUM}
		CI_BUILD_NAME=${CIRCLE_PROJECT_USERNAME}-${CIRCLE_PROJECT_REPONAME}-${CIRCLE_BRANCH}
	elif [ ! -z $TRAVIS ]; then
		citype="TRAVIS"
		CI_BUILD_NUM=${TRAVIS_BUILD_NUMBER}
		CI_BUILD_NAME=${TRAVIS_REPO_SLUG}-${TRAVIS_BRANCH}
	elif [ ! -z $JENKINS_URL ]; then
		citype="JENKINS"
		CI_BUILD_NUM=${BUILD_NUMBER}
		CI_BUILD_NAME=${JOB_NAME}-${GIT_BRANCH}
	else
		citype="UNKNOWN"
		CI_BUILD_NUM=
		CI_BUILD_NAME=
	fi
	echo "Current CI Server is $citype .."
}

setReportFile;

if [ -z $rptfile ]; then
	echo "No report file found .. Cannot proceed. Aborting ..."
	exit 1;
fi 

echo "Using $rptfile as the report-task file"

setCiInfo;
echo "Current CI Server is $citype CI_BUILD_NUM = $CI_BUILD_NUM, CI_BUILD_NAME=$CI_BUILD_NAME.."

srv=`grep serverUrl ${rptfile} | awk -F= '{print $2}'`
ceTaskId=`grep ceTaskId ${rptfile} | awk -F= '{print $2}'`
echo "Sonar Task Id = ${ceTaskId}"

#Set sonar related information in variables prefixed with SONAR_ and export them
export SONAR_CETASKID=${ceTaskId}

dashboardUrl=`grep dashboardUrl  ${rptfile} | awk -F= '{print $2}'`
echo "DashboardUrl = $dashboardUrl"

export SONAR_DASHBOARDURL=${dashboardUrl}

taskstatus="PENDING"

# Sonar analysis is async so may not be done immediately
analysisComplete=false

# If we want to get Quality gate Status then we have to wait
# for analysis to complete. But this may block for too long.
# We will do this based on WAIT_FOR_ANALYSIS environment variable
# but default to true in this version

waitForAnalysis=${WAIT_FOR_ANALYSIS:-true}
echo "Wait for Analysis is $waitForAnalysis"

# If we want to fail the build based on Quality Gate Status
# we will do it based on the first argument $1, assumed by default to be true
# Note: if set to true, but analysis is not complete, then it will be ignored
#
failBuildOnQG=${1:-true}
echo "Fail Build if Quality Gate Status is ERROR = $failBuildOnQG"

if [ "$waitForAnalysis" == "true" ]; then
	waitForAnalysisToComplete;
else
	echo "Not waiting for analysis to complete."
	echo "We will set taskstatus in the environment variable"
	echo "Task Id and Task Status should be used later on to get Quality Gate Status"
fi

export SONAR_TASKSTATUS="$taskstatus";

if [ -z $CI_BUILD_NUM ]; then
	echo "CI_BUILD_NUM is not configured .."
	echo "Artifactory Build Info management skipped ..."
else

	# Get JFrog CLI
	curl -fL https://getcli.jfrog.io | sh

	# configure artifactory
	./jfrog rt config jf1  --url $ARTIFACTORY_URL --user $ARTIFACTORY_USER --apikey $ARTIFACTORY_APIKEY --interactive=false

        # Please modify to match the artifacts to be uploaded for your project
        ./jfrog rt u "*/*.jar" $ARTIFACTORY_REPO --build-name=$CI_BUILD_NAME --build-number=$CI_BUILD_NUM --flat=false --server-id=jf1 

	# read env vars
	./jfrog rt bce $CI_BUILD_NAME $CI_BUILD_NUM

	# Publish build info
	./jfrog rt bp $CI_BUILD_NAME $CI_BUILD_NUM --server-id=jf1

fi


if [ "$failBuildOnQG" == "true" ]; then
	echo "We will fail the build if Quality Gate Status has ERROR"
	echo "QGSTATUS = $qgstatus"
	if [ "$qgstatus" == "ERROR" ]; then
		echo "Failing the build as Quality Gate Status has ERROR.."
		exit 1;
	else
		echo "Not Failing the build as Sonar task status is $taskstatus and Quality Gate Status is $qgstatus.."
	fi
else
	echo "Not Failing the build as it is not enabled .."
fi

