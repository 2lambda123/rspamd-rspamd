*** Settings ***
Suite Setup     Rspamd Redis Setup
Suite Teardown  Rspamd Redis Teardown
Library         ${RSPAMD_TESTDIR}/lib/rspamd.py
Resource        ${RSPAMD_TESTDIR}/lib/rspamd.robot
Variables       ${RSPAMD_TESTDIR}/lib/vars.py

*** Variables ***
${CONFIG}                         ${RSPAMD_TESTDIR}/configs/known_senders.conf
${SETTINGS_REPLIES}               {symbols_enabled = [REPLIES_CHECK, REPLIES_SET, REPLY]}
${REDIS_SCOPE}                    Suite
${RSPAMD_SCOPE}                   Suite

*** Test Cases ***
UNKNOWN SENDER
  Scan File  ${RSPAMD_TESTDIR}/messages/spam_message.eml
  ...  Settings={symbols_enabled [KNOWN_SENDER]}
  Do Not Expect Symbol  KNOWN_SENDER
  Expect Symbol  UNKNOWN_SENDER

UNKNOWN SENDER BECOMES KNOWN
  Scan File  ${RSPAMD_TESTDIR}/messages/spam_message.eml
  ...  Settings={symbols_enabled [KNOWN_SENDER]}
  Expect Symbol  KNOWN_SENDER
  Do Not Expect Symbol  UNKNOWN_SENDER

UNKNOWN SENDER WRONG DOMAIN
  Scan File  ${RSPAMD_TESTDIR}/messages/empty_part.eml
  ...  Settings={symbols_enabled [KNOWN_SENDER]}
  Do Not Expect Symbol  KNOWN_SENDER
  Do Not Expect Symbol  UNKNOWN_SENDER

UNKNOWN SENDER WRONG DOMAIN RESCAN
  Scan File  ${RSPAMD_TESTDIR}/messages/empty_part.eml
  ...  Settings={symbols_enabled [KNOWN_SENDER]}
  Do Not Expect Symbol  KNOWN_SENDER
  Do Not Expect Symbol  UNKNOWN_SENDER
  
INCOMING MAIL SENDER IS KNOWN
  Scan File  ${RSPAMD_TESTDIR}/messages/set_replyto_1_1.eml
  ...  IP=8.8.8.8  User=user@emailbl.com
  ...  Settings=${SETTINGS_REPLIES}
  Scan File  ${RSPAMD_TESTDIR}/messages/replyto_1_1.eml
  ...  IP=8.8.8.8  User=user@emailbl.com
  ...  Settings=${SETTINGS_REPLIES}
  Scan File  ${RSPAMD_TESTDIR}/messages/inc_mail_known_sender.eml
  ...  IP=8.8.8.8  User=user@emailbl.com
  ...  Settings={symbols_enabled [INC_MAIL_KNOWN]}
  Expect Symbol  INC_MAIL_KNOWN
  
INCOMING MAIL SENDER IS UNKNOWN
  Scan File  ${RSPAMD_TESTDIR}/messages/replyto_1_1.eml
  ...  Settings={symbols_enabled [INC_MAIL_KNOWN]}
  Do Not Expect Symbol  INC_MAIL_KNOWN
