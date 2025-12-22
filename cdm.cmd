@echo off
pushd "%~dp0"
powershell -ExecutionPolicy Bypass -File cdm.ps1 %*
popd