#!/usr/bin/env bash
set -eu

#set variables
r_ver="${r_ver:-"4.1.0"}"
ampvis2_rel="${ampvis2_rel:-"2.7.11"}"
image_name="${image_name:-"kasperskytte/rstudio_r${r_ver}_ampvis2:${ampvis2_rel}"}"
password="${password:-"supersafepassword"}"
port="${port:-"8787"}" #will generate a random one if unavailable
RENV_PATHS_CACHE_HOST="${HOME}/.local/share/renv/cache" #path to renv cache on host, renv default is ~/.local/share/renv/cache
RENV_PATHS_CACHE_CONTAINER="/usr/local/lib/R/renv-cache/" #path to renv cache within the container (dont have to change)
num_threads=$(($(nproc) - 2)) #all cores except 2
#done setting variables

#optionally build the image instead of pulling
build=${1:-""}
if [ "$build" == "build" ]
then
  #build the container image
  echo "Creating temporary folder for the Dockerfile..."
  tmpdir=$(mktemp -dt "rstudio_r${r_ver}_ampvis2:${ampvis2_rel}_XXXXX")
  pushd "$tmpdir" > /dev/null

  cat << Dockerfile > Dockerfile
  FROM rocker/rstudio:${r_ver}

  #multithreaded make
  ENV MAKEFLAGS="-j ${num_threads} "
  ENV CRAN=https://mirrors.dotsrc.org/cran

  #install nice-to-have system dependencies for R, and netstat to scan ports
  ARG DEBIAN_FRONTEND=noninteractive
  RUN apt-get update -qqy && \\
    apt-get install -y --no-install-recommends --no-install-suggests \\
      libxml2-dev \\
      libcairo2-dev \\
      libxt-dev \\
      libjpeg-dev \\
      net-tools \\
      libharfbuzz-dev \\
      libfribidi-dev \\
      libfreetype6-dev \\
      libpng-dev \\
      libtiff5-dev

  #set default renv cache path in container
  #change CRAN mirror from https://packagemanager.rstudio.com to AAU mirror
  #install renv, and install all packages in the lock file to /usr/local/lib/R/site-library/ in container
  RUN echo "RENV_PATHS_CACHE=${RENV_PATHS_CACHE_CONTAINER}" >> /usr/local/lib/R/etc/Renviron.site && \\
    echo "options(repos = c(CRAN = 'https://mirrors.dotsrc.org/cran/'), download.file.method = 'libcurl')" >> /usr/local/lib/R/etc/Rprofile.site && \\
    R -e "install.packages('renv', Ncpus = ${num_threads})" && \\
    R -e "renv::consent(provided = TRUE)" && \\
    R -e "renv::restore( \\
      library = '/usr/local/lib/R/site-library/', \\
      rebuild = TRUE, \\
      clean = TRUE, \\
      lockfile = 'https://raw.githubusercontent.com/MadsAlbertsen/ampvis2/${ampvis2_rel}/renv.lock', \\
      prompt = FALSE)"
  RUN R -e "renv::install('madsalbertsen/ampvis2@${ampvis2_rel}')"

  #enable users to install R packages
  RUN chown 1000:1000 -R /usr/local/lib/R/site-library /usr/local/lib/R/library

  #silence RStudio warnings about not being able to write dictionary stuff to /root
  VOLUME /root
Dockerfile
  docker build -t "${image_name}" .
  echo "Removing temporary folder..."
  popd > /dev/null && rm -rf "$tmpdir"
else
  docker pull "${image_name}"
fi

checkPort() {
  randomPort() {
    echo $(( ( RANDOM % 60000 )  + 1025 ))
  }
  local port
  local check_port
  check_port=${1:-"$(randomPort)"}

  while [ -n "$check_port" ]
  do
    port="$check_port"
    check_port=$(docker run --rm --net=host ${image_name} netstat -atn | grep "$port" || :)
    if [ -n "$check_port" ]
    then
      check_port="$(randomPort)"
    fi 
  done
  echo "$port"
}

port=$(checkPort "$port")

mkdir -p ${RENV_PATHS_CACHE_HOST}

#launch the container with the host cache mounted in the container
docker run -d \
  -e "PASSWORD=${password}" \
  -e "RENV_PATHS_CACHE=${RENV_PATHS_CACHE_CONTAINER}" \
  -v "${RENV_PATHS_CACHE_HOST}:${RENV_PATHS_CACHE_CONTAINER}" \
  -v "$HOME":/home/rstudio \
  -p "$port":8787 \
  ${image_name}

echo
echo "Launch RStudio through a browser at one of these adresses:"
echo "http://127.0.0.1:${port} (this machine only)"
for IP in $(hostname -I)
do
  echo "http://${IP}:${port}"
done
echo
echo "Username: rstudio"
echo "Password: ${password}"
