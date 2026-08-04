set -ex

cat custom_vars/custom_var

grep 'OTP_VERSION: 2[4-6]\.' custom_vars/custom_var
