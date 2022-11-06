#!/bin/bash
#### FALTA DEPURAR CÓDIGO
# ----------------- FUNCIONES -----------------

function f_crearimagen {
      # Crea una imagen nueva, que utilice bullseye-base.qcow2 como imagen base
      #y tenga 5 GiB de tamaño máximo. Esta imagen se denominará maquina1.qcow2.
      echo -e "Creando nueva imagen...\n"
      qemu-img create -f qcow2 maquina1.qcow2 5G -b bullseye-base-1.qcow2 1>/dev/null
      echo -e "\nRealizado."
      sleep 2
      #Redimensionamos el disco ya que la imagen creada anteriormente es de 3G y esta de 5G.
      echo -e "Redimensionando el disco...\n"
      cp maquina1.qcow2 newmaquina1.qcow2
      virt-resize --expand /dev/vda1 maquina1.qcow2 newmaquina1.qcow2
      echo -e "Copiando el disco redimensionado..."
      cp newmaquina1.qcow2 maquina1.qcow2
      rm newmaquina1.qcow2
      echo -e"\nRealizado."
}

function f_crearred {
      # Crea una red interna de nombre intra con salida al exterior mediante
      # NAT que utilice el direccionamiento 10.10.20.0/24.
      echo -e "\nCreando red intra..."
      echo -e "<network>\n  <name>intra</name>\n  <forward mode='nat'/>\n  <domain name='intra'/>\n  <ip address='10.10.20.1' netmask='255.255.255.0'>\n    <dhcp>\n      <range start='10.10.20.100' end='10.10.20.254'/>\n    </dhcp>\n  </ip>\n</network>" > ./intra.xml
      virsh -c qemu:///system net-define ./intra.xml
      virsh -c qemu:///system net-start intra
}

function f_crearmaquina {
      #Crea una máquina virtual (maquina1) conectada a la red intra, con 1 GiB de RAM,
      #que utilice como disco raíz maquina1.qcow2 y que se inicie automáticamente. Arranca
      #la máquina. Modifica el fichero /etc/hostname con maquina1.
      echo -e "Esperando a que el sistema se inicie...\n"
      echo -e "¡¡¡¡¡ATENCIÓN!!!!! CIERRA LA CONSOLA DESPUÉS DE QUE SE HAYA INICIADO EL SISTEMA\n"
      virt-install --connect qemu:///system \
      --virt-type kvm \
      --name maquina1 \
      --disk ./maquina1.qcow2 \
      --import \
      --memory 1024 \
      --vcpus 2 \
      --network network=intra \
      --os-variant debian10 \
      #Con el noautoconsole no me funciona el ssh y sin embargo los comando los ejecuto fuera del script y funcionan.
      #--noautoconsole
      #guardamos la ip en una variable para ejecutar los comandos por ssh.
      echo -e "modificando el hostname\n"
      #Tenemos que modificar el fichero hosts y hostname para cambiar el nombre de la máquina.
      ip=$(virsh -c qemu:///system domifaddr maquina1 --full | egrep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
      ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i clavepriv debian@$ip sudo sed -i 's/debian/maquina1/g' "/etc/hosts"
      ssh -i clavepriv debian@$ip sudo sed -i 's/debian/maquina1/g' "/etc/hostname"
      ssh -i clavepriv debian@$ip 'echo -e "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf'      
}

function f_voladd {
      #Crea un volumen adicional de 1 GiB de tamaño en formato RAW ubicado en el pool por defecto
      echo -e "Creando el volumen adicional...\n"
      virsh -c qemu:///system vol-create-as default newvol.raw 1G --format raw
      echo -e "Realizado.\n"
}

function f_reinicio {
      #REINICIAMOS LA MÁQUINA PARA QUE SE CAMBIE EL HOSTNAME
      virsh -c qemu:///system destroy maquina1
      virsh -c qemu:///system start maquina1
      echo -e "Esperando a que el sistema se inicie...\n"
      sleep 20
}

function f_mount {
      # Una vez iniciada la MV maquina1, conecta el volumen a la máquina, crea un sistema de ficheros XFS en el volumen y 
      # móntalo en el directorio /var/www/html. Ten cuidado con los propietarios y grupos que pongas,
      # para que funcione adecuadamente el siguiente punto.
      ### Asociamos el disco a la máquina virtual
      virsh -c qemu:///system attach-disk maquina1 /var/lib/libvirt/images/newvol.raw vdb --driver=qemu --type disk --subdriver raw --persistent
      ### Instalamos el paquete de xfs y creamos el sistema de ficheros xfs
      ssh -i clavepriv debian@$ip sudo apt install xfsprogs -y
      ssh -i clavepriv debian@$ip sudo mkfs.xfs /dev/vdb
      ### Instalamos apache2 para montar el disco que hemos añadido anteriormente
      ssh -i clavepriv debian@$ip sudo apt install apache2 -y
      ssh -i clavepriv debian@$ip "sudo -- bash -c 'echo "/dev/vdb /var/www/html xfs defaults 0 0" >> /etc/fstab'"
      #Hacemos un mount -a para montar todo lo que hay en el fstab.
      ssh -i clavepriv debian@$ip "sudo mount -a"
      #copiamos un index.html al servidor me da casque
      scp -i clavepriv ./index.html debian@$ip:~/
      ssh -i clavepriv debian@$ip "sudo mv ~/index.html /var/www/html"
      ssh -i clavepriv debian@$ip "sudo chown www-data /var/www/html/index.html"
}

function f_pausa {
      # Muestra por pantalla la dirección IP de máquina1. Pausa el
      # script y comprueba que puedes acceder a la página web.
      echo -e "la ip de la maquina1 es: $ip\n"
      echo "accede al servidor web.\n"
      read -rsp $'Pulsa una tecla para continuar...\n' -n 1 key
}

function f_installlxc {
      # Instala LXC y crea un linux container llamado container1.
      ssh -i clavepriv debian@$ip "sudo apt install lxc -y"
      ssh -i clavepriv debian@$ip "sudo lxc-create lxc-create -n container1 -t debian"
}

function f_addbr0 {
      # Añade una nueva interfaz a la máquina virtual para conectarla a la red pública (al punte br0).
      virsh -c qemu:///system attach-interface --domain maquina1 --type bridge --source br0 --model virtio --config
      #tenía pensado guardar en una variable de entorno el nombre de la 3a interfaz 
      #de un ip a que sería la red a configurar, pero da Errores las variables de 
      #entorno a traves de ssh. Dejo enp8s0 que es la segunda interfaz que añade.      
      ssh -i clavepriv debian@$ip 'echo -e "\nallow hotplug enp8s0\niface enp8s0 inet dhcp" | sudo tee -a /etc/network/interfaces'
      #reinicio la máquina para que aplique la configuración
      f_reinicio
      
}

function f_showip {
      # Muestra la nueva IP que ha recibido.
      ssh -i clavepriv debian@$ip "sudo -- bash -c 'dhclient -r && dhclient'"
      sleep 10
      ip_nueva=$(ssh -i clavepriv debian@$ip "ip a show enp8s0 | grep inet | cut -d/ -f1 | head -n 1 | grep -oP '(\d+\.){3}\d+'" | sed 's/ //g')
      echo "La ip del br0 es $ip_nueva"
}

function f_aumento {
      # Apaga maquina1 y auméntale la RAM a 2 GiB y vuelve a iniciar la máquina.
      virsh -c qemu:///system destroy maquina1
      virsh -c qemu:///system setmaxmem --domain maquina1 2G --config
      virsh -c qemu:///system setmem --domain maquina1 2G --config
      virsh -c qemu:///system start maquina1
      ### Crea un snapshot de la máquina virtual.
      virsh -c qemu:///system snapshot-create-as --domain maquina1 --name snap_maquina1 --disk-only --atomic
}



# ------------------------ MAIN ------------------------
quien=$(id -u)
      if [[ $quien -ne 0 ]]
      then
            f_crearimagen
            f_crearred
            f_crearmaquina
            f_voladd
            f_reinicio
            f_mount
            f_pausa
            f_installlxc
            f_addbr0
            f_showip
            f_aumento
      else
            echo "No hay que ejecutar el script como root."
      fi

### La función de este trozo de código es validar que todos las funciones se ejecutan correctamente.
#quien=$(id -u)
#      if [[ $quien -ne 0 ]]
#      then
#            f_crearimagen
#            if [[ $? -eq 0 ]]
#            then 
#                  echo "La imagen se ha creado correctamente."
#                  f_crearred
#                  if [[ $? -eq 0 ]]
#                  then
#                        echo "La red se ha creado correctamente."
#                        f_crearmaquina
#                        if [[ $? -eq 0 ]]
#                        then
#                              echo "La máquina ha sido creada correctamente"
#                              f_voladd
#                              if [[ $? -eq 0 ]]
#                              then
#                                    echo "El volumen ha sido añadido correctamente."
#                                    f_reinicio
#                                    if [[ $? -eq 0 ]]
#                                    then
#                                          f_mount
#                                          if [[ $? -eq 0 ]]
#                                          then
#                                                echo "El disco se ha montado correctamente."
#                                                f_pausa
#                                                if [[ $? -eq 0 ]]
#                                                then
#                                                      f_installlxc
#                                                      if [[ $? -eq 0 ]]
#                                                      then
#                                                            echo "LXC se ha instalado correctamente."
#                                                            f_addbr0
#                                                            if [[ $? -eq 0 ]]
#                                                            then
#                                                                  echo "El bridge br0 se ha añadido correctamente."
#                                                                  f_showip
#                                                                  if [[ $? -eq 0 ]]
#                                                                  then
#                                                                        f_aumento
#                                                                        if [[ $? -eq 0 ]]
#                                                                        then
#                                                                              echo "La memoria RAM se ha aumentado correctamente."
#                                                                        else
#                                                                              echo "Error al aumentar la memoria ram."
#                                                                        fi
#                                                                  else
#                                                                        echo "Error al mostrar la ip."
#                                                                  fi
#                                                            else
#                                                                  echo "Error al crear el brige"
#                                                            fi
#                                                      else
#                                                            echo "Error al instalar o crear la máquina en lxc."
#                                                      fi
#                                                else
#                                                      echo "Error al pausar la máquina"
#                                                fi
#                                          else
#                                                echo "Error al montar el disco."
#                                          fi
#                                    else
#                                          echo "Error al reiniciar la máquina."
#                                    fi
#                              else                     
#                                    echo "Error  al añadir el volumen."
#                              fi
#                        else
#                              echo "Error al crear la máquina."
#                        fi
#                  else
#                        echo "Error al crear la red."
#                  fi
#            else
#                  echo "Error al crear la imagen."
#            fi
#      else
#            echo "No hay que ejecutar el script como root."
#      fi