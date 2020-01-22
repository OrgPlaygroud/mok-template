/*
executionMasks:
  jwt-role-glg: 0
glgjwtComment: 'Flag [0] includes = DENY_ALL'
*/

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT PHONE
FROM USER_TABLE
WHERE USER_ID = 1
