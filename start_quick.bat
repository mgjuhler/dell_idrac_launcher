@echo off

set drachost="IP"
set dracuser="USER"
set dracpwd="PASSWORD"

C:\jre\bin\java.exe -cp avctKVM.jar -Djava.library.path=.\lib com.avocent.idrac.kvm.Main ip=%drachost% kmport=5900 vport=5900 user=%dracuser% passwd=%dracpwd% apcp=1 version=2 vmprivilege=true "helpurl=https://%drachost%:443/help/contents.html"