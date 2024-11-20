#!/usr/bin/env bash

set -e

SKOPEO_CMD=${SKOPEO_CMD:-skopeo}
AUTH_FILE=${AUTH_FILE:-}

MIN_MINOR=${MIN_MINOR:-12}

# shellcheck source=opm_utils.sh
source opm_utils.sh

package_name="kubevirt-hyperconverged"

helpFunction()
{
  echo -e "Usage: $0\n"
  echo -e "\t--help:   see all commands of this script\n"
  echo -e "\t--init-basic <OCP_minor> <yq|jq>:   initialize a new composite fragment\n\t  example: $0 --init-basic v4.13 yq\n"
  echo -e "\t--init-basic-all:   initialize all the fragments from production\n\t  example: $0 --init-basic-all\n"
  echo -e "\t--comment-graph <OCP_minor>:   add human readable bundle tags as comments to graph generated by --init-basic\n\t  example: $0 --comment-graph v4.13\n"
  echo -e "\t--render <OCP_minor> <brew>: render one FBC fragment\n\t\"brew\" optional parameter will made it consuming bundle images from the brew registry\n\t  example: $0 --render v4.13 brew\n"
  echo -e "\t--render-all <brew>: render all the FBC fragments\n\t\"brew\" optional parameter will made it consuming bundle images from the brew registry\n\t  example: $0 --render-all brew\n"
  exit 1
}

devfile()
{
    cat <<EOT > "$1"/devfile.yaml
schemaVersion: 2.2.0
metadata:
  name: fbc-$1
  displayName: FBC $1
  description: 'File based catalog'
  language: fbc
  provider: Red Hat
components:
  - name: image-build
    image:
      imageName: ""
      dockerfile:
        uri: catalog.Dockerfile
        buildContext: ""
  - name: kubernetes
    kubernetes:
      inlined: placeholder
    attributes:
      deployment/container-port: 50051
      deployment/cpuRequest: "100m"
      deployment/memoryRequest: 512Mi
      deployment/replicas: 1
      deployment/storageRequest: "0"
commands:
  - id: build-image
    apply:
      component: image-build
EOT
}

dockerfile()
{
    suffix="-rhel9"
    if [[ "$1" =~ ^v4.1(1|2|3|4)$ ]]; then suffix="" ; fi

    cat <<EOT > "$1"/catalog.Dockerfile
# The base image is expected to contain
# /bin/opm (with a serve subcommand) and /bin/grpc_health_probe
FROM registry.redhat.io/openshift4/ose-operator-registry${suffix}:$1

# Configure the entrypoint and command
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

# Copy declarative config root into image at /configs and pre-populate serve cache
ADD catalog /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

# Set DC-specific label for the location of the DC root directory
# in the image
LABEL operators.operatorframework.io.index.configs.v1=/configs
EOT
}

setBrew()
{
if [[ "$2" == "brew" ]]; then
    sed -i 's|image: registry.redhat.io/container-native-virtualization/hco-bundle-registry|image: brew.registry.redhat.io/container-native-virtualization/hco-bundle-registry|g' "${frag}"/graph.yaml
fi
}

unsetBrew()
{
if [[ "$2" == "brew" ]]; then
    sed -i 's|image: brew.registry.redhat.io/container-native-virtualization/hco-bundle-registry|image: registry.redhat.io/container-native-virtualization/hco-bundle-registry|g' "${frag}"/graph.yaml
    sed -i 's|brew.registry.redhat.io/container-native-virtualization/hco-bundle-registry|registry.redhat.io/container-native-virtualization/hco-bundle-registry|g' "${frag}"/catalog/kubevirt-hyperconverged/catalog.json
fi
}


cmd="$1"
case $cmd in
  "--help")
    helpFunction
  ;;
  "--init-basic")
    frag=$2
    if [ -z "$frag" ]
    then
      echo "Please specify OCP minor, eg: v4.12"
      exit 1
    fi
    FROMV=$(grep FROM "${frag}"/catalog.Dockerfile)
    OCPV=${FROMV##*:}
    from=registry.redhat.io/redhat/redhat-operator-index:${OCPV}
    yqOrjq=$3
    mkdir -p "${frag}/catalog/kubevirt-hyperconverged/" "${frag}/${frag}"
    touch "${frag}/${frag}/.empty"
    case $yqOrjq in
      "yq")
        touch "${frag}"/graph.yaml
# shellcheck disable=SC2086
	./opm render $(opm_alpha_params "${frag}") "$from" -o yaml | \
	    yq "select( .package == \"$package_name\" or .name == \"$package_name\")" | \
      yq 'select(.schema != "olm.bundle" or .name == null or .name | capture("v4\.(?<minor>\d+)\.\d+") | .minor | to_number | . >= '${MIN_MINOR}')' | \
      yq 'select(.schema == "olm.bundle") = {"schema": .schema, "image": .image}' | \
      yq 'select(.schema == "olm.package") = {"schema": .schema, "name": .name, "defaultChannel": .defaultChannel}' | \
      yq 'select(.schema == "olm.channel") = {"entries": .entries | filter(.name | capture("v4\.(?<minor>\d+)\.\d+") | .minor | to_number | . >= '${MIN_MINOR}'), "name": .name, "package": .package, "schema": .schema}' | \
      yq '[.]' | \
      yq '{"schema": "olm.template.basic", "name": "kubevirt-hyperconverged", "entries":.}' | \
      sed 's|^  #|    #|g' > "${frag}/graph.yaml"
      ;;
      "jq")
# shellcheck disable=SC2086
        ./opm render $(opm_alpha_params "${frag}") "$from" | jq "select( .package == \"$package_name\" or .name == \"$package_name\")" | \
            jq 'if (.schema == "olm.bundle") then {schema: .schema, image: .image} else (if (.schema == "olm.package") then {schema: .schema, name: .name, defaultChannel: .defaultChannel} else . end) end' | \
            jq -s | \
            jq '{"schema": "olm.template.basic", "name": "kubevirt-hyperconverged", "entries": .}' > "${frag}"/graph.json
      ;;
      *)
        echo "please specify if yq or jq"
        exit 1
      ;;
    esac
    devfile "$frag"
    dockerfile "$frag"
  ;;
  "--init-basic-all")
    for f in ./"v4."*; do
      frag=${f#./}
      $0 --init-basic "${frag}" yq
      $0 --comment-graph "${frag}"
    done
  ;;
  "--render")
    frag=$2
    if [ -z "$frag" ]
    then
      echo "Please specify OCP minor, eg: v4.12"
      exit 1
    fi
    echo "rendering catalog for ${frag}..."
    setBrew "${frag}" "$3"
# shellcheck disable=SC2086
    ./opm alpha render-template basic $(opm_alpha_params "${frag}") "${frag}"/graph.yaml > "${frag}"/catalog/kubevirt-hyperconverged/catalog.json
    unsetBrew "${frag}" "$3"
    echo "rendered catalog for ${frag}."
  ;;
  "--render-all")
    for f in ./"v4."*; do
      frag=${f#./}
      echo "rendering catalog for ${frag}..."
      setBrew "${frag}" "$2"
# shellcheck disable=SC2086
      ./opm alpha render-template basic $(opm_alpha_params "${frag}") "${frag}"/graph.yaml > "${frag}"/catalog/kubevirt-hyperconverged/catalog.json
      unsetBrew "${frag}" "$2"
      echo "rendered catalog for ${frag}."
    done
  ;;
  "--comment-graph")
    frag=$2
    if [ -z "$frag" ]
    then
      echo "Please specify OCP minor, eg: v4.12"
      exit 1
    fi
    setBrew "${frag}" "$3"
    sed -i "/# hco-bundle-registry v4\./d" "$frag"/graph.yaml
    grep -E "image: [brew\.]*registry.redhat.io/container-native-virtualization/hco-bundle-registry[-rhel9]*@sha256" "$frag"/graph.yaml | while read -r line ; do
      image=${line/image: /}
      echo "Processing $image"
      # shellcheck disable=SC2086
      url=$(${SKOPEO_CMD} inspect --no-tags ${AUTH_FILE} "docker://$image" | grep "\"url\": ")
      tag1=${url/*\/images\/}
      tag=${tag1/\",/}
      sed -i -E "s|^( *)(image: )$image|\1\2$image\n\1# hco-bundle-registry $tag|g" "$frag"/graph.yaml
    done
    unsetBrew "${frag}" "$3"
  ;;
  "--comment-graph-all")
    for f in ./"v4."*; do
      frag=${f#./}
      setBrew "${frag}" "$2"
      sed -i "/# hco-bundle-registry v4\./d" "$frag"/graph.yaml
      grep -E "image: [brew\.]*registry.redhat.io/container-native-virtualization/hco-bundle-registry[-rhel9]*@sha256" "$frag"/graph.yaml | while read -r line ; do
        image=${line/image: /}
        echo "Processing $image"
	# shellcheck disable=SC2086
        url=$(${SKOPEO_CMD} inspect --no-tags ${AUTH_FILE} docker://"$image" | grep "\"url\": ")
        tag1=${url/*\/images\/}
        tag=${tag1/\",/}
        sed -i -E "s|^( *)(image: )$image|\1\2$image\n\1# hco-bundle-registry $tag|g" "$frag"/graph.yaml
      done
      unsetBrew "${frag}" "$2"
    done
  ;;
  *)
    echo "$cmd not one of the allowed flags"
    helpFunction
  ;;
esac
