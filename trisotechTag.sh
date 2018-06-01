#!/bin/bash
DATE=$(date "+%Y-%m-%d")

# removing KIE artifacts from local maven repo (basically all possible SNAPSHOTs)
echo $MAVEN_REPO_LOCAL "="

if [ -d $MAVEN_REPO_LOCAL ]; then
    rm -rf $MAVEN_REPO_LOCAL/org/kie/
    rm -rf $MAVEN_REPO_LOCAL/org/drools/
    rm -rf $MAVEN_REPO_LOCAL/org/jbpm/
    rm -rf $MAVEN_REPO_LOCAL/org/optaplanner/  
fi

mvnVersionsSet() {
    mvn -B -N -e -Dfull versions:set -DnewVersion="$newVersion" -DallowSnapshots=true -DgenerateBackupPoms=false
}

mvnVersionsUpdateParent() {
    mvn -B -N -e versions:update-parent -Dfull\
     -DparentVersion="[$newVersion]" -DallowSnapshots=true -DgenerateBackupPoms=false
}

mvnVersionsUpdateChildModules() {
    mvn -B -N -e versions:update-child-modules -Dfull\
     -DallowSnapshots=true -DgenerateBackupPoms=false
}

# Updates parent version and child modules versions for Maven project in current working dir
mvnVersionsUpdateParentAndChildModules() {
    mvnVersionsUpdateParent
    mvnVersionsUpdateChildModules
}


# clones, changes versions, build, tags and pushes the tags

for REPOSITORY_URL in `cat $TRISO` ; do
   echo

   if [ ! -d $REPOSITORY_URL ]; then
      echo "==============================================================================="
      echo "Repository: $REPOSITORY_URL"
      echo "==============================================================================="

      cd $WORKSPACE
      git clone $REPOSITORY_URL --branch $branch
      echo $REPOSITORY_URL > rep.txt
      REP_DIR=$(sed -e 's/.*\///' -e 's/.\{4\}$//' rep.txt)
      echo "rep_dir="$REP_DIR
      cd $REP_DIR 
      
        if [ "$REP_DIR" == "kie-soup" ]; then
            mvnVersionsSet
            cd kie-soup-bom
            mvnVersionsSet
            cd ..
            mvn -B -U -Dfull -s $SETTINGS_XML_FILE clean install -DskipTests
            returnCode=$?

        elif [ "$REP_DIR" == "droolsjbpm-build-bootstrap" ]; then
            # first build&install the current version (usually SNAPSHOT) as it is needed later by other repos
            mvn -B -U -Dfull clean install
            mvnVersionsSet
            sed -i "s/<version\.org\.kie>.*<\/version.org.kie>/<version.org.kie>$newVersion<\/version.org.kie>/" pom.xml
            # update latest released version property only for non-SNAPSHOT versions
            if [[ ! $newVersion == *-SNAPSHOT ]]; then
                sed -i "s/<latestReleasedVersionFromThisBranch>.*<\/latestReleasedVersionFromThisBranch>/<latestReleasedVersionFromThisBranch>$newVersion<\/latestReleasedVersionFromThisBranch>/" pom.xml
            fi
            # update version also for user BOMs, since they do not use the top level kie-parent
            cd kie-user-bom-parent
            mvnVersionsSet
            cd ..
            # workaround for http://jira.codehaus.org/browse/MVERSIONS-161
            mvn -B clean install -DskipTests
            returnCode=$?
        
        elif [ "$REP_DIR" == "drlx-parser" ]; then
            #update version in drlx-parser/pom.xml
            cd drlx-parser
            mvnVersionsUpdateParent
            cd ..
            returnCode=$?
            
        else
            mvnVersionsUpdateParentAndChildModules
            returnCode=$?
        fi

        if  [ $returnCode != 0 ] ; then
            exit $returnCode
        fi
 
        git add .
        git commit -m "upgraded to $newVersion"
        
        # create a tag
        commitMsg="Tagging $tag $DATE"
        git tag -a $tag -m "$commitMsg"
        
        if [ "$target" == "community" ]; then 
           deployDir=$WORKSPACE/tristotech-deploy-dir
           mvn -B -e clean deploy -T1C -Dfull -Drelease -Dkie.maven.settings.custom=$SETTINGS_XML_FILE -DaltDeploymentRepository=local::default::file://$deployDir -Dmaven.test.redirectTestOutputToFile=true -Dmaven.test.failure.ignore=true -Dgwt.compiler.localWorkers=2\
 -Dgwt.memory.settings="-Xmx4g -Xms1g -Xss1M"
        
        else
           deployDir=$WORKSPACE/trisotech-deploy-dir
           mvn -B -e clean deploy -T1C -Dfull -Drelease  -DaltDeploymentRepository=local::default::file://$deployDir -Dmaven.test.redirectTestOutputToFile=true -Dmaven.test.failure.ignore=true -Dgwt.compiler.localWorkers=3\
 -Dproductized -Dgwt.memory.settings="-Xmx4g -Xms1g -Xss1M"
        fi
        

  fi       
done  

# copies binaries to nexus
if [ "$target" == "community" ]; then
   stagingRep=15c58a1abc895b
else
   stagingRep=15c3321d12936e
fi

cd $deployDir
# upload the content to remote staging repo
mvn -B -e org.sonatype.plugins:nexus-staging-maven-plugin:1.6.5:deploy-staged-repository -DnexusUrl=https://repository.jboss.org/nexus -DserverId=jboss-releases-repository\
 -DrepositoryDirectory=$deployDir -DstagingProfileId=$stagingRep -DstagingDescription="Trisotech-$newVersion" -DstagingProgressTimeoutMinutes=30

# push tags has to be on own for loop to prevent tags pushed to early

for REPOSITORY_URL in `cat $TRISO` ; do
   echo

   if [ ! -d $REPOSITORY_URL ]; then
      echo "==============================================================================="
      echo "Repository: $REPOSITORY_URL"
      echo "==============================================================================="

      cd $WORKSPACE
      echo $REPOSITORY_URL > rep.txt
      REP_DIR=$(sed -e 's/.*\///' -e 's/.\{4\}$//' rep.txt)
      echo "rep_dir="$REP_DIR
      cd $REP_DIR 
      
      git push origin $tag
      
   fi
done
