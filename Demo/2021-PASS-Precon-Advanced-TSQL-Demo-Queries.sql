---------------------------------------------------------------------
-- Advanced T-SQL Querying and Query Tuning
-- © Itzik Ben-Gan
-- For more, see 5-day Advanced T-SQL class: http://tsql.Lucient.com
---------------------------------------------------------------------

-- Sample databases TSQLV5: http://tsql.Lucient.com/SampleDatabases/TSQLV5.zip
-- Sample databases PerformanceV5: http://tsql.Lucient.com/SampleDatabases/PerformanceV5.zip

---------------------------------------------------------------------
-- Search arguments
---------------------------------------------------------------------

USE TSQLV5;

-- Not SARG
SELECT orderid, shippeddate
FROM Sales.Orders
WHERE YEAR(shippeddate) = 2018;

-- SARG
SELECT orderid, shippeddate
FROM Sales.Orders
WHERE shippeddate >= '20180101'
  AND shippeddate < '20190101';

-- Careful with NULLs!

DECLARE @dt AS DATE = '20190101'; -- also try with NULL

-- SARG, incorrect
SELECT orderid, shippeddate
FROM Sales.Orders
WHERE shippeddate = @dt;

-- Correct, not SARG
SELECT orderid, shippeddate
FROM Sales.Orders
WHERE ISNULL(shippeddate, '99991231') = ISNULL(@dt, '99991231');

-- Correct, ugly SARG
SELECT orderid, shippeddate
FROM Sales.Orders
WHERE shippeddate = @dt
   OR (shippeddate IS NULL AND @dt IS NULL);

-- Correct, elegant SARG
SELECT orderid, shippeddate
FROM Sales.Orders
WHERE EXISTS(SELECT shippeddate INTERSECT SELECT @dt);

---------------------------------------------------------------------
-- Join ordering optimization
---------------------------------------------------------------------

-- Don't force order
SELECT DISTINCT C.companyname AS customer, S.companyname AS supplier
FROM Sales.Customers AS C
  INNER JOIN Sales.Orders AS O
    ON O.custid = C.custid
  INNER JOIN Sales.OrderDetails AS OD
    ON OD.orderid = O.orderid
  INNER JOIN Production.Products AS P
    ON P.productid = OD.productid
  INNER JOIN Production.Suppliers AS S
    ON S.supplierid = P.supplierid;

-- Force order
SELECT DISTINCT C.companyname AS customer, S.companyname AS supplier
FROM Sales.Customers AS C
  INNER JOIN Sales.Orders AS O
    ON O.custid = C.custid
  INNER JOIN Sales.OrderDetails AS OD
    ON OD.orderid = O.orderid
  INNER JOIN Production.Products AS P
    ON P.productid = OD.productid
  INNER JOIN Production.Suppliers AS S
    ON S.supplierid = P.supplierid
OPTION (FORCE ORDER);

-- Join O with OD first, then C with result
-- Use as physical order
SELECT DISTINCT C.companyname AS customer, S.companyname AS supplier
FROM Sales.Customers AS C
  INNER JOIN 
    ( Sales.Orders AS O
        INNER JOIN Sales.OrderDetails AS OD
          ON OD.orderid = O.orderid )
      ON O.custid = C.custid
  INNER JOIN Production.Products AS P
    ON P.productid = OD.productid
  INNER JOIN Production.Suppliers AS S
    ON S.supplierid = P.supplierid
OPTION (FORCE ORDER);

-- Include customers with no matches
SELECT DISTINCT C.companyname AS customer,S.companyname AS supplier
FROM Sales.Customers AS C
  LEFT OUTER JOIN
    ( Sales.Orders AS O
        INNER JOIN Sales.OrderDetails AS OD
          ON OD.orderid = O.orderid
        INNER JOIN Production.Products AS P
          ON P.productid = OD.productid
        INNER JOIN Production.Suppliers AS S
          ON S.supplierid = P.supplierid )
      ON O.custid = C.custid;

---------------------------------------------------------------------
-- Batch-mode processing and batch mode on rowstore
---------------------------------------------------------------------

USE PerformanceV5;

-- Set compatibility to 140 to prevent batch mode on rowstore
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 140;

-- Query optimized with row-mode processing
SELECT empid, COUNT(*) AS numorders
FROM dbo.Orders
GROUP BY empid;

-- Create columnstore index
CREATE NONCLUSTERED COLUMNSTORE INDEX idx_nc_cs ON dbo.Orders(orderid, custid, empid, shipperid, orderdate, filler);

-- Query optimized with batch-mode processing (both EE and SE)
SELECT empid, COUNT(*) AS numorders
FROM dbo.Orders
GROUP BY empid;

-- Drop columnstore index and set compatibility to 150
DROP INDEX IF EXISTS idx_nc_cs ON dbo.Orders;
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 150;

-- Query optimized with batch-mode processing on EE and row_mode processing on SE
SELECT empid, COUNT(*) AS numorders
FROM dbo.Orders
GROUP BY empid;

-- Query optimized with row-mode prcessing since size requirement isn't met (2^17)
SELECT empid, COUNT(*) AS numorders
FROM (SELECT TOP(131071) * FROM dbo.Orders) AS D
GROUP BY empid;

-- Create dummy filtered columnstore index
CREATE NONCLUSTERED COLUMNSTORE INDEX idx_cs
  ON dbo.Orders(orderid)
  WHERE orderid = -1 AND orderid = -2;

-- Query optimized with batch-mode processing (both EE and SE)
SELECT empid, COUNT(*) AS numorders
FROM dbo.Orders
GROUP BY empid;

-- Query optimized with batch-mode processing (both EE and SE)
SELECT empid, COUNT(*) AS numorders
FROM (SELECT TOP(131071) * FROM dbo.Orders) AS D
GROUP BY empid;

-- Cleanup
DROP INDEX IF EXISTS idx_cs ON dbo.Orders;

----------------------------------------------------------------------
-- Adaptive Join
----------------------------------------------------------------------

USE PerformanceV5;

EXEC sys.sp_helpindex 'dbo.Orders';

-- Indexing
DROP INDEX IF EXISTS idx_nc_cn_i_cid ON dbo.Customers;
DROP INDEX IF EXISTS idx_nc_cid_od_i_oid_eid_sid ON dbo.Orders;

CREATE INDEX idx_nc_cn_i_cid 
  ON dbo.Customers(custname) INCLUDE(custid);

CREATE INDEX idx_nc_cid_od_i_oid_eid_sid
  ON dbo.Orders(custid, orderdate)
  INCLUDE(orderid, empid, shipperid);
GO

-- Create dbo.GetOrders procedure
CREATE OR ALTER PROC dbo.GetOrders
  @custprefix NVARCHAR(200) = N'',
  @fromdate AS DATE = '19000101',
  @todate AS DATE = '99991231'
AS

SET NOCOUNT ON;

SELECT C.custid, C.custname, O.orderid, O.empid, O.shipperid, O.orderdate
FROM dbo.Customers AS C
  INNER JOIN dbo.Orders AS O
    ON O.custid = C.custid
WHERE C.custname LIKE @custprefix + N'%'
  AND O.orderdate BETWEEN @fromdate AND @todate;
GO

-- high selectivity
EXEC dbo.GetOrders
  @custprefix = N'Cust[_]1000',
  @fromdate = '20190101',
  @todate = '20190430';

-- low selectivity
EXEC dbo.GetOrders
  @custprefix = N'Cust[_]10',
  @fromdate = '20190101',
  @todate = '20190430';

-- Remove plan from cache and retry above executions in opposite order
EXEC sp_recompile 'dbo.GetOrders';

-- Enable Adaptive Join with dummy columnstore index
CREATE NONCLUSTERED COLUMNSTORE INDEX idx_showmethemoney
  ON dbo.Orders(orderid) WHERE orderid = -1 AND orderid = -2;

-- Cleanup
DROP INDEX IF EXISTS idx_nc_cn_i_cid ON dbo.Customers;
DROP INDEX IF EXISTS idx_nc_cid_od_i_oid_eid_sid ON dbo.Orders;
DROP INDEX IF EXISTS idx_showmethemoney ON dbo.Orders;
DROP PROC IF EXISTS dbo.GetOrders;

----------------------------------------------------------------------
-- STRING_SPLIT
----------------------------------------------------------------------

USE TSQLV5;
GO

-- 2016+
CREATE OR ALTER PROC dbo.GetOrders(@orderids AS VARCHAR(8000))
AS

SELECT O.orderid, O.orderdate, O.custid, O.empid
FROM Sales.Orders AS O
  INNER JOIN STRING_SPLIT(@orderids, ',') AS K
    ON O.orderid = CAST(K.value AS INT);
GO
   
EXEC dbo.GetOrders @orderids = '10248,10249,10250';
GO

-- Solution to fixed cardinality issue
CREATE NONCLUSTERED COLUMNSTORE INDEX idx_dontworrybehappy
  ON Sales.Orders(orderid)
  WHERE orderid = -1 AND orderid = -2;

EXEC dbo.GetOrders @orderids = '10248,10249,10250';

EXEC dbo.GetOrders @orderids = '10643,10692,10702,10835,10952,11011,10308,10625,10759,10926,10365,10507,10535,10573,10677,10682,10856,10355,10383,10453,10558,10707,10741,10743,10768,10793,10864,10920,10953,11016,10278,10280,10384,10444,10445,10524,10572,10626,10654,10672,10689,10733,10778,10837,10857,10866,10875,10924,10501,10509,10582,10614,10853,10956,11058,10265,10297,10360,10436,10449,10559,10566,10584,10628,10679,10826,10326,10801,10970,10331,10340,10362,10470,10511,10525,10663,10715,10730,10732,10755,10827,10871,10876,10932,10940,11076,10389,10410,10411,10431,10492,10742,10918,10944,10949,10975,10982,11027,11045,11048';

-- Cleanup
DROP INDEX idx_dontworrybehappy ON Sales.Orders;
DROP PROC IF EXISTS dbo.GetOrders;

----------------------------------------------------------------------
-- Interleaved execution
----------------------------------------------------------------------

USE PerformanceV5;
GO

DROP TABLE IF EXISTS dbo.Nums;
GO

-- Populate Nums with 1M rows
SELECT ISNULL(CAST(n AS INT), 0) AS n INTO dbo.Nums FROM dbo.GetNums(1, 1000000);
ALTER TABLE dbo.Nums ADD CONSTRAINT PK_Nums PRIMARY KEY(n);
GO

-- Multi-statement TVF returning table variable with individual elements
CREATE OR ALTER FUNCTION dbo.Split(@arr AS VARCHAR(MAX), @sep AS CHAR(1))
  RETURNS @T TABLE(pos INT NOT NULL PRIMARY KEY, val VARCHAR(8000) NOT NULL)
AS
BEGIN
  INSERT INTO @T(pos, val)
    SELECT
      ROW_NUMBER() OVER(ORDER BY n) AS pos,
      SUBSTRING(@arr, n, CHARINDEX(@sep, @arr + @sep, n) - n) AS val
    FROM dbo.Nums AS N
    WHERE n <= LEN(@arr) + 1
      AND SUBSTRING(@sep + @arr, n, 1) = @sep;

  RETURN;
END;
GO

-- Actual number of rows is 10000; optimal strategy is hash join
-- Estimated number of rows 100 since using multi-statement TVF forcing 130 compat level; getting loop join
DECLARE @orderids AS VARCHAR(MAX) = (SELECT STRING_AGG(CAST(orderid AS VARCHAR(MAX)), ',') FROM dbo.Orders WHERE orderid % 100 = 0);

SELECT O.orderid, O.orderdate, O.custid, O.empid
FROM dbo.Split(@orderids, ',') AS S
  INNER JOIN dbo.Orders AS O
    ON O.orderid = CAST(S.val AS INT)
OPTION(USE HINT('query_optimizer_compatibility_level_130'));
GO

-- Under compat level >= 140, getting interleaved execution with hash join
DECLARE @orderids AS VARCHAR(MAX) = (SELECT STRING_AGG(CAST(orderid AS VARCHAR(MAX)), ',') FROM dbo.Orders WHERE orderid % 100 = 0);

SELECT O.orderid, O.orderdate, O.custid, O.empid
FROM dbo.Split(@orderids, ',') AS S
  INNER JOIN dbo.Orders AS O
    ON O.orderid = CAST(S.val AS INT);
GO

---------------------------------------------------------------------
-- Deferred compilation
---------------------------------------------------------------------

-- Run actually on 2017
-- Or on 2019 with compatibility_level 140
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 140;
USE PerformanceV5;
GO

DECLARE @orderids AS VARCHAR(MAX) = (SELECT STRING_AGG(CAST(orderid AS VARCHAR(MAX)), ',') FROM dbo.Orders WHERE orderid % 100 = 0);

DECLARE @T TABLE(pos INT NOT NULL PRIMARY KEY, val VARCHAR(8000) NOT NULL);

INSERT INTO @T(pos, val)
  SELECT
    ROW_NUMBER() OVER(ORDER BY n) AS pos,
    SUBSTRING(@orderids, n, CHARINDEX(',', @orderids + ',', n) - n) AS val
  FROM dbo.Nums AS N
  WHERE n <= LEN(@orderids) + 1
    AND SUBSTRING(',' + @orderids, n, 1) = ',';

SELECT O.orderid, O.orderdate, O.custid, O.empid
FROM @T AS S
  INNER JOIN dbo.Orders AS O
    ON O.orderid = CAST(S.val AS INT);
GO

-- 2019
USE PerformanceV5;
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 150;
GO

DECLARE @orderids AS VARCHAR(MAX) = (SELECT STRING_AGG(CAST(orderid AS VARCHAR(MAX)), ',') FROM dbo.Orders WHERE orderid % 100 = 0);

DECLARE @T TABLE(pos INT NOT NULL PRIMARY KEY, val VARCHAR(8000) NOT NULL);

INSERT INTO @T(pos, val)
  SELECT
    ROW_NUMBER() OVER(ORDER BY n) AS pos,
    SUBSTRING(@orderids, n, CHARINDEX(',', @orderids + ',', n) - n) AS val
  FROM dbo.Nums AS N
  WHERE n <= LEN(@orderids) + 1
    AND SUBSTRING(',' + @orderids, n, 1) = ',';

SELECT O.orderid, O.orderdate, O.custid, O.empid
FROM @T AS S
  INNER JOIN dbo.Orders AS O
    ON O.orderid = CAST(S.val AS INT);
GO

---------------------------------------------------------------------
-- Scalar UDF inlining
---------------------------------------------------------------------

-- Takling scalar UDF performance problem
USE PerformanceV5;
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 140;
DBCC OPTIMIZER_WHATIF(CPUs, 8); -- emulate 8 CPUs for costing purposes
GO

SET STATISTICS TIME ON;

-- Parallel
SELECT *
FROM dbo.Orders
WHERE orderdate = DATEADD(year, DATEDIFF(year, '18991231', orderdate), '18991231');

-- Serial
SELECT *
FROM dbo.Orders
WHERE orderdate = DATEADD(year, DATEDIFF(year, '18991231', orderdate), '18991231')
OPTION(MAXDOP 1);

-- Encapsulate logic in scalar UDF
DROP FUNCTION IF EXISTS dbo.EndOfYear;
GO

CREATE OR ALTER FUNCTION dbo.EndOfYear(@dt AS DATE) RETURNS DATE
AS
BEGIN
  RETURN DATEADD(year, DATEDIFF(year, '18991231', @dt), '18991231');
END;
GO

SELECT *
FROM dbo.Orders
WHERE orderdate = dbo.EndOfYear(orderdate);

-- Switch back to compat level 150 and rerun query above
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 150;

-- Cleanup CPUs setting
DBCC OPTIMIZER_WHATIF(ResetAll); -- emulate 8 CPUs for costing purposes
GO

---------------------------------------------------------------------
-- Memory grant feedback
---------------------------------------------------------------------

USE PerformanceV5;
GO

-- Run a few times and check memry grant info on root node 
DECLARE @od AS DATE = '20191231';

SELECT *
FROM dbo.Orders
WHERE orderdate >= @od
ORDER BY orderid;
GO

---------------------------------------------------------------------
-- Approximate QP
---------------------------------------------------------------------

-- APPROX_COUNT_DISTINCT
USE PerformanceV5;

--DROP TABLE IF EXISTS dbo.BigTable;
--SELECT CHECKSUM(NEWID()) % 25000000 AS col1 INTO dbo.BigTable FROM dbo.GetNums(1, 25000000);

SET STATISTICS TIME ON;

-- CPU time = 8157 ms, elapsed time = 2221 ms, memory = 1.8 GB
SELECT COUNT(DISTINCT col1) AS cnt_col1 FROM dbo.BigTable;

-- CPU time = 6250 ms, elapsed time = 1713 ms, memory = 12 MB
SELECT APPROX_COUNT_DISTINCT(col1) AS apxcnt_col1 FROM dbo.BigTable;

SET STATISTICS TIME OFF;

---------------------------------------------------------------------
-- APPLY
---------------------------------------------------------------------

USE TSQLV5;

-- CROSS APPLY
SELECT C.custid, A.orderid, A.orderdate, A.empid
FROM Sales.Customers AS C
  CROSS APPLY ( SELECT TOP (3) orderid, orderdate, empid
                FROM Sales.Orders AS O
                WHERE O.custid = C.custid
                ORDER BY orderdate DESC, orderid DESC ) AS A;

-- OUTER APPLY
SELECT C.custid, A.orderid, A.orderdate, A.empid
FROM Sales.Customers AS C
  OUTER APPLY ( SELECT TOP (3) orderid, orderdate, empid
                FROM Sales.Orders AS O
                WHERE O.custid = C.custid
                ORDER BY orderdate DESC, orderid DESC ) AS A;
GO

-- Used with a function
DROP FUNCTION IF EXISTS dbo.GetTopOrders;
GO

CREATE OR ALTER FUNCTION dbo.GetTopOrders(@custid AS INT, @n AS BIGINT)
  RETURNS TABLE
AS
RETURN
  SELECT TOP (@n) orderid, orderdate, empid
  FROM Sales.Orders AS O
  WHERE O.custid = @custid
  ORDER BY orderdate DESC, orderid DESC;
GO

SELECT C.custid, A.orderid, A.orderdate, A.empid
FROM Sales.Customers AS C
  CROSS APPLY dbo.GetTopOrders( C.custid, 3 ) AS A;
GO

---------------------------------------------------------------------
-- Converting scalar UDFs to inline TVFs
---------------------------------------------------------------------

-- Before SQL Server 2019, scalar UDF do not get inlined
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 140;
DBCC OPTIMIZER_WHATIF(CPUs, 8);
GO

SET STATISTICS TIME ON;

USE PerformanceV5;

SELECT *
FROM dbo.Orders
WHERE orderdate = DATEADD(year, DATEDIFF(year, '18991231', orderdate), '18991231');
GO

DROP FUNCTION IF EXISTS dbo.EndOfYear;
GO

CREATE OR ALTER FUNCTION dbo.EndOfYear(@dt AS DATE) RETURNS DATE
AS
BEGIN
  RETURN DATEADD(year, DATEDIFF(year, '18991231', @dt), '18991231');
END;
GO

-- No inlining
SELECT *
FROM dbo.Orders
WHERE orderdate = dbo.EndOfYear(orderdate);

-- Convert scalar UDF to inline TVF
DROP FUNCTION IF EXISTS dbo.EndOfYear;
GO

CREATE OR ALTER FUNCTION dbo.EndOfYear(@dt AS DATE) RETURNS TABLE
AS
  RETURN SELECT DATEADD(year, DATEDIFF(year, '18991231', @dt), '18991231') AS endofyear;
GO

SELECT O.*
FROM dbo.Orders AS O
  CROSS APPLY dbo.EndOfYear(orderdate) AS F
WHERE O.orderdate = F.endofyear;
GO

-- Cleanup
DROP FUNCTION IF EXISTS dbo.EndOfYear;
DBCC OPTIMIZER_WHATIF(ResetAll);
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 150;

---------------------------------------------------------------------
-- Using APPLY to get a seek-based strategy
---------------------------------------------------------------------

---------------------------------------------------------------------
-- Example with grouping and aggregation
---------------------------------------------------------------------

USE PerformanceV5;

-- Make sure columnstore indexes are not present and compatibility is 140
EXEC sys.sp_helpindex 'dbo.Orders';
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 140;
GO

DROP INDEX IF EXISTS idx_nc_sid_od ON dbo.Orders;
DROP INDEX IF EXISTS idx_empid ON dbo.Orders;
GO

SELECT empid, MAX(orderdate) AS maxod
FROM dbo.Orders
GROUP BY empid;

---------------------------------------------------------------------
-- Preordered Stream Aggregate
---------------------------------------------------------------------

CREATE INDEX idx_empid ON dbo.Orders(empid, orderdate);

SELECT empid, MAX(orderdate) AS maxod
FROM dbo.Orders
GROUP BY empid;

DROP INDEX IF EXISTS idx_empid ON dbo.Orders;

---------------------------------------------------------------------
-- Sort + Stream Aggregate
---------------------------------------------------------------------

SELECT empid, MAX(orderdate) AS maxod
FROM (SELECT TOP (100) * FROM dbo.Orders) AS D
GROUP BY empid;

---------------------------------------------------------------------
-- Hash Aggregate
---------------------------------------------------------------------

SELECT empid, MAX(orderdate) AS maxod
FROM (SELECT TOP (10000) * FROM dbo.Orders) AS D
GROUP BY empid;

---------------------------------------------------------------------
-- Return maximum order date per shipper
---------------------------------------------------------------------

-- Supporting index
CREATE INDEX idx_sid_od ON dbo.Orders(shipperid, orderdate);

-- Scan
SELECT shipperid, MAX(orderdate) AS maxod
FROM dbo.Orders
GROUP BY shipperid;

-- Seeks
SELECT S.shipperid, O.maxod
FROM dbo.Shippers AS S
  CROSS APPLY ( SELECT TOP (1) O.orderdate
                FROM dbo.Orders AS O
                WHERE O.shipperid = S.shipperid
                ORDER BY O.orderdate DESC ) AS O(maxod);

-- Cleanup
DROP INDEX IF EXISTS idx_sid_od ON dbo.Orders;
ALTER DATABASE PerformanceV5 SET COMPATIBILITY_LEVEL = 150;

---------------------------------------------------------------------
-- Top N per Group
---------------------------------------------------------------------

USE TSQLV5;

-- POC index
CREATE UNIQUE INDEX idx_poc
  ON Sales.Orders(custid, orderdate DESC, orderid DESC)
  INCLUDE(empid);

-- ROW_NUMBER, POC + Low Density
WITH C AS
(
  SELECT 
    ROW_NUMBER() OVER(
      PARTITION BY custid
      ORDER BY orderdate DESC, orderid DESC) AS rownum,
    orderid, orderdate, custid, empid
  FROM Sales.Orders
)
SELECT custid, orderdate, orderid, empid
FROM C
WHERE rownum <= 3;

-- APPLY, POC + High Density
SELECT C.custid, A.*
FROM Sales.Customers AS C
  CROSS APPLY ( SELECT TOP (3) orderid, orderdate, empid
                FROM Sales.Orders AS O
                WHERE O.custid = C.custid
                ORDER BY orderdate DESC, orderid DESC ) AS A;

-- Cleanup
DROP INDEX IF EXISTS Sales.Orders.idx_POC;

---------------------------------------------------------------------
-- Reuse of Column Aliases
---------------------------------------------------------------------

USE TSQLV5;

SELECT orderid, orderyear
FROM Sales.Orders
  CROSS APPLY ( VALUES( YEAR(orderdate) ) ) AS A1(orderyear)
  CROSS APPLY ( VALUES( DATEFROMPARTS(orderyear, 12, 31) ) ) AS A2(endofyear)
WHERE orderdate = endofyear;

---------------------------------------------------------------------
-- Aggregate over columns (alternative to GREATEST/LEAST)
---------------------------------------------------------------------

-- Code to Create and Populate the Sales Table
USE tempdb;
IF OBJECT_ID('dbo.Sales', 'U') IS NOT NULL DROP TABLE dbo.Sales;
GO

CREATE TABLE dbo.Sales
(
  custid    VARCHAR(10) NOT NULL,
  qty2018   INT   NULL,
  qty2019   INT   NULL,
  qty2020   INT   NULL,
  val2018   MONEY NULL,
  val2019   MONEY NULL,
  val2020   MONEY NULL,
  CONSTRAINT PK_Sales PRIMARY KEY(custid)
);

INSERT INTO dbo.Sales
    (custid, qty2018, qty2019, qty2020, val2018, val2019, val2020)
  VALUES
    ('A', 606,113,781,4632.00,6877.00,4815.00),
    ('B', 243,861,637,2125.00,8413.00,4476.00),
    ('C', 932,117,202,9068.00,342.00,9083.00),
    ('D', 915,833,138,1131.00,9923.00,4164.00),
    ('E', 822,246,870,1907.00,3860.00,7399.00);

-- Aggregate over columns
SELECT custid,
  qty2018, qty2019, qty2020, maxqty,
  val2018, val2019, val2020, maxval
FROM dbo.Sales
  CROSS APPLY ( SELECT MAX(qty), MAX(val)
                FROM ( VALUES(qty2018, val2018),
                             (qty2019, val2019),
                             (qty2020, val2020) ) AS D(qty, val) ) AS D(maxqty, maxval);
GO

-- Aggregate over variables
DECLARE @p1 AS INT = 10, @p2 AS INT = 5, @p3 AS INT = 15;

DECLARE @mx AS INT = ( SELECT MAX(val) FROM ( VALUES(@p1),(@p2),(@p3) ) AS D(val) );

SELECT @mx AS maxval;
GO

---------------------------------------------------------------------
-- Flexible unpivoting with multiple measures and control over NULLs
---------------------------------------------------------------------

-- Sample data
USE TSQLV5;

DROP TABLE IF EXISTS dbo.PvtOrders;

SELECT *
INTO dbo.PvtOrders
FROM (SELECT custid, YEAR(orderdate) AS orderyear, val
      FROM Sales.OrderValues) AS D
  PIVOT(SUM(val) FOR orderyear IN([2017],[2018],[2019])) AS P;

SELECT * FROM dbo.PvtOrders;
GO

-- Using the UNPIVOT operator

SELECT custid, orderyear, val
FROM dbo.PvtOrders
  UNPIVOT(val FOR orderyear IN([2017],[2018],[2019])) AS U;

---------------------------------------------------------------------
-- Unpivoting with CROSS APPLY
---------------------------------------------------------------------

SELECT custid, orderyear, val
FROM dbo.PvtOrders
  CROSS APPLY ( VALUES( 2017, [2017] ),
                      ( 2018, [2018] ),
                      ( 2019, [2019] ) ) AS A( orderyear, val )
WHERE val IS NOT NULL;

---------------------------------------------------------------------
-- Aggregates over Partitioned Tables
---------------------------------------------------------------------

-- Creating Sample Data

-- Create sample database TestMinMax
SET NOCOUNT ON;
USE master;
DROP DATABASE IF EXISTS TestMinMax;
GO
CREATE DATABASE TestMinMax
GO
USE TestMinMax;
GO

-- Create and populate partitioned table T1
CREATE PARTITION FUNCTION PF1 (INT)
AS RANGE LEFT FOR VALUES (200000, 400000, 600000, 800000);

CREATE PARTITION SCHEME PS1
AS PARTITION PF1 ALL TO ([PRIMARY]);

CREATE TABLE dbo.T1
(
  col1 INT NOT NULL,
  col2 INT NOT NULL,
  filler BINARY(200) NOT NULL DEFAULT(0x01)
) ON PS1(col1);

CREATE UNIQUE CLUSTERED INDEX idx_col1 ON dbo.T1(col1) ON PS1(col1);
CREATE NONCLUSTERED INDEX idx_col2 ON dbo.T1(col2) ON PS1(col1);

INSERT INTO dbo.T1 WITH (TABLOCK) (col1, col2)
  SELECT n, CHECKSUM(NEWID()) FROM TSQLV5.dbo.GetNums(1, 1000000);
GO

-- Stats ON
SET STATISTICS IO, TIME ON;

-- Query 1
-- Efficient because applying aggregate to partitioning column
SELECT MAX(col1) AS mx
FROM dbo.T1;

-- Query 2
-- Inefficient because applying aggregate to nonpartitioning column
-- even though index exists on col2 due to optimization bug
SELECT MAX(col2) AS mx
FROM dbo.T1;

-- Query 3
-- Example showing efficient index use with one partition
SELECT MAX(col2) AS pmx
FROM dbo.T1
WHERE $PARTITION.PF1(col1) = 1;

-- Query 4
-- Workaround to original need MAX(col2) with dynamic querying of partitions in table
SELECT MAX(A.pmx) AS mx
FROM sys.partitions AS P
  CROSS APPLY ( SELECT MAX(T1.col2) AS pmx
                FROM dbo.T1
                WHERE $PARTITION.PF1(T1.col1) = P.partition_number ) AS A
WHERE P.object_id = OBJECT_ID('dbo.T1')
  AND P.index_id = INDEXPROPERTY( OBJECT_ID('dbo.T1'), 'idx_col2', 'IndexID' );

-- Stats OFF
SET STATISTICS IO, TIME OFF;

-- Cleanup
USE master;
DROP DATABASE IF EXISTS TestMinMax;

---------------------------------------------------------------------
-- Window functions
---------------------------------------------------------------------

---------------------------------------------------------------------
-- Frameless aggregates
---------------------------------------------------------------------

USE TSQLV5;

SELECT orderid, custid, val,
  CAST(100. * val / SUM(val) OVER()                    AS NUMERIC(5, 2)) AS pctall,
  CAST(100. * val / SUM(val) OVER(PARTITION BY custid) AS NUMERIC(5, 2)) AS pctcust
FROM Sales.OrderValues;

---------------------------------------------------------------------
-- Ranking
---------------------------------------------------------------------

USE tempdb;

DROP TABLE IF EXISTS dbo.Orders;

CREATE TABLE dbo.Orders
(
  orderid   INT        NOT NULL,
  orderdate DATE       NOT NULL,
  empid     INT        NOT NULL,
  custid    VARCHAR(5) NOT NULL,
  qty       INT        NOT NULL,
  CONSTRAINT PK_Orders PRIMARY KEY NONCLUSTERED(orderid)
);
GO

CREATE UNIQUE CLUSTERED INDEX idx_UC_orderdate_orderid
  ON dbo.Orders(orderdate, orderid);

INSERT INTO dbo.Orders(orderid, orderdate, empid, custid, qty)
  VALUES(30001, '20190802', 3, 'B', 10),
        (10001, '20191224', 1, 'C', 10),
        (10005, '20191224', 1, 'A', 30),
        (40001, '20200109', 4, 'A', 40),
        (10006, '20200118', 1, 'C', 10),
        (20001, '20200212', 2, 'B', 20),
        (40005, '20200212', 4, 'A', 10),
        (20002, '20200216', 2, 'C', 20),
        (30003, '20200418', 3, 'B', 15),
        (30004, '20200418', 3, 'B', 20),
        (30007, '20200907', 3, 'C', 30);
GO

-- Ranking without partitioning
SELECT orderid, qty,
  ROW_NUMBER() OVER(ORDER BY qty) AS rownum,
  RANK()       OVER(ORDER BY qty) AS rnk,
  DENSE_RANK() OVER(ORDER BY qty) AS densernk,
  NTILE(4)     OVER(ORDER BY qty) AS ntile4
FROM dbo.Orders;

-- Ranking with partitioning
SELECT custid, orderid, qty,
  ROW_NUMBER() OVER(PARTITION BY custid ORDER BY orderid) AS rownum
FROM dbo.Orders
ORDER BY custid, orderid;

---------------------------------------------------------------------
-- Framed aggregates
---------------------------------------------------------------------

USE TSQLV5;

-- If executed in 2019, either turn off batch mode on rowstore or use compatibility_level = 140 to demonstrate pre-2019 optimization
ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_ON_ROWSTORE = OFF;
ALTER DATABASE TSQLV5 SET COMPATIBILITY_LEVEL = 140;

-- Sample data
IF OBJECT_ID('dbo.Transactions', 'U') IS NOT NULL DROP TABLE dbo.Transactions;
IF OBJECT_ID('dbo.Accounts', 'U') IS NOT NULL DROP TABLE dbo.Accounts;

CREATE TABLE dbo.Accounts
(
  actid INT NOT NULL CONSTRAINT PK_Accounts PRIMARY KEY
);

CREATE TABLE dbo.Transactions
(
  actid  INT   NOT NULL,
  tranid INT   NOT NULL,
  val    MONEY NOT NULL,
  CONSTRAINT PK_Transactions PRIMARY KEY(actid, tranid) -- creates POC index
);

DECLARE
  @num_partitions     AS INT = 100,
  @rows_per_partition AS INT = 20000;

INSERT INTO dbo.Accounts WITH (TABLOCK) (actid)
  SELECT NP.n
  FROM dbo.GetNums(1, @num_partitions) AS NP;

INSERT INTO dbo.Transactions WITH (TABLOCK) (actid, tranid, val)
  SELECT NP.n, RPP.n,
    (ABS(CHECKSUM(NEWID())%2)*2-1) * (1 + ABS(CHECKSUM(NEWID())%5))
  FROM dbo.GetNums(1, @num_partitions) AS NP
    CROSS JOIN dbo.GetNums(1, @rows_per_partition) AS RPP;
GO

-- Query using ROWS
SELECT actid, tranid, val,
  SUM(val) OVER(PARTITION BY actid
                ORDER BY tranid
                ROWS UNBOUNDED PRECEDING) AS balance
FROM dbo.Transactions;

-- Query using RANGE (implied)
SELECT actid, tranid, val,
  SUM(val) OVER(PARTITION BY actid
                ORDER BY tranid) AS balance
FROM dbo.Transactions;

---------------------------------------------------------------------
-- Offset
---------------------------------------------------------------------

USE tempdb;
-- Same sample data like for ranking

-- LAG and LEAD
SELECT custid, orderid, orderdate, qty,
  LAG(qty)  OVER(PARTITION BY custid
                 ORDER BY orderdate, orderid) AS prevqty,
  LEAD(qty) OVER(PARTITION BY custid
                 ORDER BY orderdate, orderid) AS nextqty
FROM dbo.Orders
ORDER BY custid, orderdate, orderid;

-- FIRST_VALUE and LAST_VALUE
SELECT custid, orderid, orderdate, qty,
  FIRST_VALUE(qty) OVER(PARTITION BY custid
                        ORDER BY orderdate, orderid
                        ROWS BETWEEN UNBOUNDED PRECEDING
                                 AND CURRENT ROW) AS firstqty,
  LAST_VALUE(qty)  OVER(PARTITION BY custid
                        ORDER BY orderdate, orderid
                        ROWS BETWEEN CURRENT ROW
                                 AND UNBOUNDED FOLLOWING) AS lastqty
FROM dbo.Orders
ORDER BY custid, orderdate, orderid;

---------------------------------------------------------------------
-- Statistical
---------------------------------------------------------------------

USE tempdb;
-- Same sample data like for ranking

SELECT DISTINCT empid,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY qty) OVER(PARTITION BY empid) AS median_cont,
  PERCENTILE_DISC(0.5) WITHIN GROUP(ORDER BY qty) OVER(PARTITION BY empid) AS median_disc
FROM dbo.Orders;

---------------------------------------------------------------------
-- Batch mode Window Aggregate
---------------------------------------------------------------------

USE TSQLV5;
ALTER DATABASE TSQLV5 SET COMPATIBILITY_LEVEL = 140;

CREATE NONCLUSTERED COLUMNSTORE INDEX idx_makeitfaster
  ON dbo.Transactions(actid)
  WHERE actid = -1 AND actid = -2;

-- Implied RANGE
SELECT actid, tranid, val,
  SUM(val) OVER(PARTITION BY actid
                ORDER BY tranid) AS balance
FROM dbo.Transactions;

-- Cleanup
DROP INDEX idx_makeitfaster ON dbo.Transactions;
ALTER DATABASE TSQLV5 SET COMPATIBILITY_LEVEL = 150;

----------------------------------------------------------------------
-- String aggregation
----------------------------------------------------------------------

-- Before SQL Server 2017

-- aggregate order IDs for a given customer
DECLARE @custid AS INT = 1;

SELECT
  STUFF(
    (SELECT ',' + CAST(orderid AS VARCHAR(10)) AS [text()]
     FROM Sales.Orders
     WHERE custid = @custid
     ORDER BY orderdate DESC, orderid DESC
     FOR XML PATH('')), 1, 1, NULL);
     
-- aggregate order IDs per customer using pre-2016 solution
SELECT C.custid,
  STUFF(
    (SELECT ',' + CAST(orderid AS VARCHAR(10)) AS [text()]
     FROM Sales.Orders AS O
     WHERE O.custid = C.custid
     ORDER BY orderdate DESC, orderid DESC
     FOR XML PATH('')), 1, 1, NULL) AS orderids
--     FOR XML PATH(''), TYPE).value('.[1]', 'VARCHAR(MAX)'), 1, 1, NULL) AS orderids
FROM Sales.Customers AS C;

-- Starting with SQL Server 2017
CREATE UNIQUE INDEX idx_cid_odD_oidD ON Sales.Orders(custid, orderdate DESC, orderid DESC);

SELECT custid,
  STRING_AGG(CAST(orderid AS VARCHAR(10)), ',')
    WITHIN GROUP(ORDER BY orderdate DESC, orderid DESC) AS orderids
FROM Sales.Orders
GROUP BY custid;

DROP INDEX idx_cid_odD_oidD ON Sales.Orders;
GO

---------------------------------------------------------------------
-- Batch mode on rowstore
---------------------------------------------------------------------

-- Enable batch mode on row store and compatibility_level = 150
-- This is ON by default
ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_ON_ROWSTORE = ON;
ALTER DATABASE TSQLV5 SET COMPATIBILITY_LEVEL = 150;

SELECT actid, tranid, val,
  SUM(val) OVER(PARTITION BY actid
                ORDER BY tranid) AS balance
FROM dbo.Transactions;

---------------------------------------------------------------------
-- Gaps and islands
---------------------------------------------------------------------

-- Create a table called T1 and fill it with sample data
SET NOCOUNT ON;
USE tempdb;
DROP TABLE IF EXISTS dbo.T1;
GO

CREATE TABLE dbo.T1
(
  col1 INT NOT NULL
    CONSTRAINT PK_T1 PRIMARY KEY
);
GO

INSERT INTO dbo.T1(col1)
  VALUES(1),(2),(3),(7),(8),(9),(11),(15),(16),(17),(28);

-- Identify gaps
WITH C AS
(
  SELECT
    col1 AS cur,
    LEAD(col1) OVER(ORDER BY col1) AS nxt
  FROM dbo.T1
)
SELECT
  cur + 1 AS range_from,
  nxt - 1 AS range_to
FROM C
WHERE nxt - cur > 1;

-- Identify islands
WITH C AS
(
  SELECT col1, col1 - DENSE_RANK() OVER(ORDER BY col1) AS grp
  FROM dbo.T1
)
SELECT MIN(col1) AS range_from, MAX(col1) AS range_to
FROM C
GROUP BY grp;

-- Stocks table
SET NOCOUNT ON;
USE tempdb;

IF OBJECT_ID('dbo.Stocks') IS NOT NULL DROP TABLE dbo.Stocks;

CREATE TABLE dbo.Stocks
(
  stockid  INT  NOT NULL,
  dt       DATE NOT NULL,
  val      INT  NOT NULL,
  CONSTRAINT PK_Stocks PRIMARY KEY(stockid, dt)
);
GO

INSERT INTO dbo.Stocks VALUES
  (1, '2020-03-01', 13),
  (1, '2020-03-02', 14),
  (1, '2020-03-03', 17),
  (1, '2020-03-04', 40),
  (1, '2020-03-05', 45),
  (1, '2020-03-06', 52),
  (1, '2020-03-07', 56),
  (1, '2020-03-08', 60),
  (1, '2020-03-09', 70),
  (1, '2020-03-10', 30),
  (1, '2020-03-11', 29),
  (1, '2020-03-12', 35),
  (1, '2020-03-13', 40),
  (1, '2020-03-14', 45),
  (1, '2020-03-15', 60),
  (1, '2020-03-16', 60),
  (1, '2020-03-17', 55),
  (1, '2020-03-18', 60),
  (1, '2020-03-19', 20),
  (1, '2020-03-20', 15),
  (1, '2020-03-21', 20),
  (1, '2020-03-22', 30),
  (1, '2020-03-23', 40),
  (1, '2020-03-24', 20),
  (1, '2020-03-25', 60),
  (1, '2020-03-26', 80),
  (1, '2020-03-27', 70),
  (1, '2020-03-28', 70),
  (1, '2020-03-29', 40),
  (1, '2020-03-30', 30),
  (1, '2020-03-31', 10),
  (2, '2020-03-01', 3),
  (2, '2020-03-02', 4),
  (2, '2020-03-03', 7),
  (2, '2020-03-04', 30),
  (2, '2020-03-05', 35),
  (2, '2020-03-06', 42),
  (2, '2020-03-07', 46),
  (2, '2020-03-08', 50),
  (2, '2020-03-09', 60),
  (2, '2020-03-10', 20),
  (2, '2020-03-11', 19),
  (2, '2020-03-12', 25),
  (2, '2020-03-13', 30),
  (2, '2020-03-14', 35),
  (2, '2020-03-15', 50),
  (2, '2020-03-16', 50),
  (2, '2020-03-17', 45),
  (2, '2020-03-18', 50),
  (2, '2020-03-19', 10),
  (2, '2020-03-20', 5),
  (2, '2020-03-21', 10),
  (2, '2020-03-22', 20),
  (2, '2020-03-23', 30),
  (2, '2020-03-24', 10),
  (2, '2020-03-25', 50),
  (2, '2020-03-26', 70),
  (2, '2020-03-27', 60),
  (2, '2020-03-28', 60),
  (2, '2020-03-29', 30),
  (2, '2020-03-30', 20),
  (2, '2020-03-31', 1);

-- Regular islands; find periods where stock value was >= 50
WITH C AS
(
  SELECT *, 
    DATEADD(day, -1*DENSE_RANK() OVER(PARTITION BY stockid ORDER BY dt), dt) AS grp
  FROM dbo.Stocks
  WHERE val >= 50
)
SELECT stockid, MIN(dt) AS startdt, MAX(dt) AS enddt, MAX(val) AS mx
FROM C
GROUP BY stockid, grp
ORDER BY stockid, startdt;

-- Advance islands; ignore gaps of up to 6 days
WITH C1 AS
(
  SELECT *, 
    CASE
      WHEN DATEDIFF(day,
             LAG(dt) OVER(PARTITION BY stockid ORDER BY dt),
             dt) < 7 THEN 0
      ELSE 1
    END AS isstart
  FROM dbo.Stocks
  WHERE val >= 50
),
C2 AS
(
  SELECT *,
    SUM(isstart) OVER(PARTITION BY stockid ORDER BY dt
                      ROWS UNBOUNDED PRECEDING) AS grp
  FROM C1
)
SELECT stockid, MIN(dt) AS startdt, MAX(dt) AS enddt, MAX(val) AS mx
FROM C2
GROUP BY stockid, grp
ORDER BY stockid, startdt;

-- Max concurrent intervals

-- Creating and Populating Sessions
SET NOCOUNT ON;
USE tempdb;

IF OBJECT_ID('dbo.Sessions', 'U') IS NOT NULL DROP TABLE dbo.Sessions;

CREATE TABLE dbo.Sessions
(
  keycol    INT         NOT NULL,
  app       VARCHAR(10) NOT NULL,
  starttime DATETIME2   NOT NULL,
  endtime   DATETIME2   NOT NULL,
  CONSTRAINT PK_Sessions PRIMARY KEY(keycol),
  CHECK(endtime > starttime)
);
GO

CREATE UNIQUE INDEX idx_start ON dbo.Sessions(app, starttime, keycol);
CREATE UNIQUE INDEX idx_end ON dbo.Sessions(app, endtime, keycol);

-- small set of sample data
TRUNCATE TABLE dbo.Sessions;

INSERT INTO dbo.Sessions(keycol, app, starttime, endtime) VALUES
  (2,  'app1', '20180201 08:30', '20180201 10:30'),
  (3,  'app1', '20180201 08:30', '20180201 08:45'),
  (5,  'app1', '20180201 09:00', '20180201 09:30'),
  (7,  'app1', '20180201 09:15', '20180201 10:30'),
  (11, 'app1', '20180201 09:15', '20180201 09:30'),
  (13, 'app1', '20180201 10:30', '20180201 14:30'),
  (17, 'app1', '20180201 10:45', '20180201 11:30'),
  (19, 'app1', '20180201 11:00', '20180201 12:30'),
  (23, 'app2', '20180201 08:30', '20180201 08:45'),
  (29, 'app2', '20180201 09:00', '20180201 09:30'),
  (31, 'app2', '20180201 11:45', '20180201 12:00'),
  (37, 'app2', '20180201 12:30', '20180201 14:00'),
  (41, 'app2', '20180201 12:45', '20180201 13:30'),
  (43, 'app2', '20180201 13:00', '20180201 14:00'),
  (47, 'app2', '20180201 14:00', '20180201 16:30'),
  (53, 'app2', '20180201 15:30', '20180201 17:00');
GO

-- desired output:
/*
app        mx
---------- -----------
app1       4
app2       3
*/

-- large set of sample data
TRUNCATE TABLE dbo.Sessions;

DECLARE 
  @numrows AS INT = 1000000, -- total number of rows 
  @numapps AS INT = 10;      -- number of applications

INSERT INTO dbo.Sessions WITH(TABLOCK)
    (keycol, app, starttime, endtime)
  SELECT
    ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS keycol, 
    D.*,
    DATEADD(
      second,
      1 + ABS(CHECKSUM(NEWID())) % (20*60),
      starttime) AS endtime
  FROM
  (
    SELECT 
      'app' + CAST(1 + ABS(CHECKSUM(NEWID())) % @numapps AS VARCHAR(10)) AS app,
      DATEADD(
        second,
        1 + ABS(CHECKSUM(NEWID())) % (30*24*60*60),
        '20180101') AS starttime
    FROM TSQLV5.dbo.GetNums(1, @numrows) AS Nums
  ) AS D;
GO

-- Traditional set-based solution
WITH TimePoints AS 
(
  SELECT app, starttime AS ts FROM dbo.Sessions
),
Counts AS
(
  SELECT app, ts,
    (SELECT COUNT(*)
     FROM dbo.Sessions AS S
     WHERE P.app = S.app
       AND P.ts >= S.starttime
       AND P.ts < S.endtime) AS concurrent
  FROM TimePoints AS P
)      
SELECT app, MAX(concurrent) AS mx
FROM Counts
GROUP BY app;

-- solution using window aggregate function
WITH C1 AS
(
  SELECT keycol, app, starttime AS ts, +1 AS type
  FROM dbo.Sessions

  UNION ALL

  SELECT keycol, app, endtime AS ts, -1 AS type
  FROM dbo.Sessions
),
C2 AS
(
  SELECT *,
    SUM(type) OVER(PARTITION BY app
                   ORDER BY ts, type, keycol
                   ROWS UNBOUNDED PRECEDING) AS cnt
  FROM C1
)
SELECT app, MAX(cnt) AS mx
FROM C2
GROUP BY app;

-- Packing intervals
SET NOCOUNT ON;
USE tempdb;

IF OBJECT_ID('dbo.Sessions') IS NOT NULL DROP TABLE dbo.Sessions;
IF OBJECT_ID('dbo.Users') IS NOT NULL DROP TABLE dbo.Users;

CREATE TABLE dbo.Users
(
  username  VARCHAR(14)  NOT NULL,
  CONSTRAINT PK_Users PRIMARY KEY(username)
);
GO

INSERT INTO dbo.Users(username) VALUES('User1'), ('User2'), ('User3');

CREATE TABLE dbo.Sessions
(
  id        INT          NOT NULL IDENTITY(1, 1),
  username  VARCHAR(14)  NOT NULL,
  starttime DATETIME2(3) NOT NULL,
  endtime   DATETIME2(3) NOT NULL,
  CONSTRAINT PK_Sessions PRIMARY KEY(id),
  CONSTRAINT CHK_endtime_gteq_starttime
    CHECK (endtime >= starttime)
);
GO

CREATE UNIQUE INDEX idx_start ON dbo.Sessions(username, starttime, id);
CREATE UNIQUE INDEX idx_end ON dbo.Sessions(username, endtime, id);
GO

INSERT INTO dbo.Sessions VALUES
  ('User1', '20181201 08:00:00.000', '20181201 08:30:00.000'),
  ('User1', '20181201 08:30:00.000', '20181201 09:00:00.000'),
  ('User1', '20181201 09:00:00.000', '20181201 09:30:00.000'),
  ('User1', '20181201 10:00:00.000', '20181201 11:00:00.000'),
  ('User1', '20181201 10:30:00.000', '20181201 12:00:00.000'),
  ('User1', '20181201 11:30:00.000', '20181201 12:30:00.000'),
  ('User2', '20181201 08:00:00.000', '20181201 10:30:00.000'),
  ('User2', '20181201 08:30:00.000', '20181201 10:00:00.000'),
  ('User2', '20181201 09:00:00.000', '20181201 09:30:00.000'),
  ('User2', '20181201 11:00:00.000', '20181201 11:30:00.000'),
  ('User2', '20181201 11:32:00.000', '20181201 12:00:00.000'),
  ('User2', '20181201 12:04:00.000', '20181201 12:30:00.000'),
  ('User3', '20181201 08:00:00.000', '20181201 09:00:00.000'),
  ('User3', '20181201 08:00:00.000', '20181201 08:30:00.000'),
  ('User3', '20181201 08:30:00.000', '20181201 09:00:00.000'),
  ('User3', '20181201 09:30:00.000', '20181201 09:30:00.000');
GO

-- For performance testing you can use the following code,
-- which creates a large set of sample data:

-- 2,000 users, 5,000,000 intervals
DECLARE 
  @num_users          AS INT          = 2000,
  @intervals_per_user AS INT          = 2500,
  @start_period       AS DATETIME2(3) = '20180101',
  @end_period         AS DATETIME2(3) = '20180107',
  @max_duration_in_ms AS INT  = 3600000; -- 60 minutes
  
TRUNCATE TABLE dbo.Sessions;
TRUNCATE TABLE dbo.Users;

INSERT INTO dbo.Users(username)
  SELECT 'User' + RIGHT('000000000' + CAST(U.n AS VARCHAR(10)), 10) AS username
  FROM TSQLV5.dbo.GetNums(1, @num_users) AS U;

WITH C AS
(
  SELECT 'User' + RIGHT('000000000' + CAST(U.n AS VARCHAR(10)), 10) AS username,
      DATEADD(ms, ABS(CHECKSUM(NEWID())) % 86400000,
        DATEADD(day, ABS(CHECKSUM(NEWID())) % DATEDIFF(day, @start_period, @end_period), @start_period)) AS starttime
  FROM TSQLV5.dbo.GetNums(1, @num_users) AS U
    CROSS JOIN TSQLV5.dbo.GetNums(1, @intervals_per_user) AS I
)
INSERT INTO dbo.Sessions WITH (TABLOCK) (username, starttime, endtime)
  SELECT username, starttime,
    DATEADD(ms, ABS(CHECKSUM(NEWID())) % (@max_duration_in_ms + 1), starttime) AS endtime
  FROM C;
GO

-- Solution 1
WITH C1 AS
(
  SELECT id, username, starttime AS ts, +1 AS type
  FROM dbo.Sessions

  UNION ALL

  SELECT id, username, endtime AS ts, -1 AS type
  FROM dbo.Sessions
),
C2 AS
(
  SELECT C1.*,
    SUM(type) OVER(PARTITION BY username
                   ORDER BY ts, type DESC, id
                   ROWS UNBOUNDED PRECEDING) AS cnt
  FROM C1
),
C3 AS
(
  SELECT username, ts, 
    (ROW_NUMBER() OVER(PARTITION BY username ORDER BY ts) - 1) / 2 + 1 AS p
  FROM C2
  WHERE type = 1 AND cnt = 1
     OR type = -1 AND cnt = 0
)
SELECT username, MIN(ts) AS starttime, max(ts) AS endtime
FROM C3
GROUP BY username, p;

-- Index for Solution 2
CREATE UNIQUE INDEX idx_start_end_id ON dbo.Sessions(username, starttime, endtime, id);

-- Solution 2
-- For details, see http://sqlmag.com/sql-server/new-solution-packing-intervals-problem
WITH C1 AS
(
  SELECT *,
    MAX(endtime) OVER(PARTITION BY username
                      ORDER BY starttime, endtime, id
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS maxend
  FROM dbo.Sessions
),
C2 AS
(
  SELECT *,
    SUM(isstart) OVER(PARTITION BY username
                      ORDER BY starttime, endtime, id
                      ROWS UNBOUNDED PRECEDING) AS grp
  FROM C1
    CROSS APPLY ( VALUES( CASE WHEN starttime <= maxend THEN 0 ELSE 1 END ) ) AS A(isstart)
)
SELECT username, MIN(starttime) AS starttime, MAX(endtime) AS endtime
FROM C2
GROUP BY username, grp;

-- Tip: In SQL Server 2016+, if you create any columnstore index, it will allow batch mode Window Aggregate
-- Create the below dummy index and then rerun the above solutions
CREATE NONCLUSTERED COLUMNSTORE INDEX idx_cs_dummy on dbo.Sessions(id) WHERE id = -1 AND id = -2;
GO

---------------------------------------------------------------------
-- Row pattern recognition (RPR)
---------------------------------------------------------------------

-- Article: https://sqlperformance.com/2019/04/t-sql-queries/row-pattern-recognition-in-sql
-- Vote to add feature to T-SQL: https://feedback.azure.com/forums/908035-sql-server/suggestions/37251232

-- Sample data
SET NOCOUNT ON;
USE TSQLV5;

DROP TABLE IF EXISTS dbo.Ticker;

CREATE TABLE dbo.Ticker
(
  symbol    VARCHAR(10)    NOT NULL,
  tradedate DATE           NOT NULL,
  price     NUMERIC(12, 2) NOT NULL,
  CONSTRAINT PK_Ticker
    PRIMARY KEY (symbol, tradedate)
);
GO

INSERT INTO dbo.Ticker(symbol, tradedate, price) VALUES
  ('STOCK1', '20190212', 150.00),
  ('STOCK1', '20190213', 151.00),
  ('STOCK1', '20190214', 148.00),
  ('STOCK1', '20190215', 146.00),
  ('STOCK1', '20190218', 142.00),
  ('STOCK1', '20190219', 144.00),
  ('STOCK1', '20190220', 152.00),
  ('STOCK1', '20190221', 152.00),
  ('STOCK1', '20190222', 153.00),
  ('STOCK1', '20190225', 154.00),
  ('STOCK1', '20190226', 154.00),
  ('STOCK1', '20190227', 154.00),
  ('STOCK1', '20190228', 153.00),
  ('STOCK1', '20190301', 145.00),
  ('STOCK1', '20190304', 140.00),
  ('STOCK1', '20190305', 142.00),
  ('STOCK1', '20190306', 143.00),
  ('STOCK1', '20190307', 142.00),
  ('STOCK1', '20190308', 140.00),
  ('STOCK1', '20190311', 138.00),
  ('STOCK2', '20190212', 330.00),
  ('STOCK2', '20190213', 329.00),
  ('STOCK2', '20190214', 329.00),
  ('STOCK2', '20190215', 326.00),
  ('STOCK2', '20190218', 325.00),
  ('STOCK2', '20190219', 326.00),
  ('STOCK2', '20190220', 328.00),
  ('STOCK2', '20190221', 326.00),
  ('STOCK2', '20190222', 320.00),
  ('STOCK2', '20190225', 317.00),
  ('STOCK2', '20190226', 319.00),
  ('STOCK2', '20190227', 325.00),
  ('STOCK2', '20190228', 322.00),
  ('STOCK2', '20190301', 324.00),
  ('STOCK2', '20190304', 321.00),
  ('STOCK2', '20190305', 319.00),
  ('STOCK2', '20190306', 322.00),
  ('STOCK2', '20190307', 326.00),
  ('STOCK2', '20190308', 326.00),
  ('STOCK2', '20190311', 324.00);

-- In standard (not supported in T-SQL)
SELECT
  MR.symbol, MR.matchnum, MR.startdate, MR.startprice,
  MR.bottomdate, MR.bottomprice, MR.enddate, MR.endprice, MR.maxprice
FROM dbo.Ticker
  MATCH_RECOGNIZE
  (
    PARTITION BY symbol
    ORDER BY tradedate
    MEASURES
      MATCH_NUMBER() AS matchnum,
      A.tradedate AS startdate,
      A.price AS startprice,
      LAST(B.tradedate) AS bottomdate,
      LAST(B.price) AS bottomprice,
      LAST(C.tradedate) AS enddate,
      LAST(C.price) AS endprice,
      MAX(price) AS maxprice
    PATTERN (A B+ C+)
    DEFINE
      -- A defaults to True
      B AS B.price < PREV(B.price),
      C AS C.price > PREV(C.price)
  ) AS MR;

-- Desired output
symbol  matchnum  startdate   startprice bottomdate  bottomprice enddate     endprice  maxprice
------- --------- ----------- ---------- ----------- ----------- ----------- --------- ---------
STOCK1  1         2019-02-13  151.00     2019-02-18  142.00      2019-02-20  152.00    152.00
STOCK1  2         2019-02-27  154.00     2019-03-04  140.00      2019-03-06  143.00    154.00
STOCK2  1         2019-02-14  329.00     2019-02-18  325.00      2019-02-20  328.00    329.00
STOCK2  2         2019-02-21  326.00     2019-02-25  317.00      2019-02-27  325.00    326.00
STOCK2  3         2019-03-01  324.00     2019-03-05  319.00      2019-03-07  326.00    326.00

-- Islands of trading activity with price >= 150, tolerating gaps of up to 3 days

-- In standard (not supported in T-SQL)
SELECT MR.symbol, MR.startdate, MR.enddate
FROM (SELECT * FROM dbo.Ticker WHERE price >= 150) AS D
  MATCH_RECOGNIZE
  (
    PARTITION BY symbol
    ORDER BY tradedate
    MEASURES FIRST(tradedate) AS startdate, LAST(tradedate) AS enddate
    PATTERN (A B*)
    DEFINE B AS B.tradedate <= DATEADD(day, 3, PREV(B.tradedate))
  ) AS MR;

-- Workaround in T-SQL as shown earlier
WITH C1 AS
(
  SELECT *,
    CASE
      WHEN
        DATEDIFF(day,
          LAG(tradedate) OVER(PARTITION BY symbol ORDER BY tradedate),
          tradedate) <= 3
        THEN 0
      ELSE 1
    END AS isstart
  FROM dbo.Ticker WHERE price >= 150
),
C2 AS
(
  SELECT *, SUM(isstart) OVER(PARTITION BY symbol ORDER BY tradedate
                              ROWS UNBOUNDED PRECEDING) AS grp
  FROM C1
)
SELECT symbol, MIN(tradedate) AS startdate, MAX(tradedate) AS enddate
FROM C2
GROUP BY symbol, grp;

---------------------------------------------------------------------
-- Nested window functions
---------------------------------------------------------------------

-- Nested row number function

-- Current order info,
-- plus difference between current order value and customer average
-- excluding first and last customer orders

-- In standard (not supported in T-SQL)
-- With nested row number function
SELECT orderid, custid, orderdate, val,
  val - AVG( CASE
               WHEN ROW_NUMBER(FRAME_ROW) NOT IN
                      ( ROW_NUMBER(BEGIN_PARTITION), ROW_NUMBER(END_PARTITION) ) THEN val
             END )
          OVER( PARTITION BY custid
                ORDER BY orderdate, orderid
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING ) AS diff
FROM Sales.OrderValues;

-- Without nested row number function
WITH C1 AS
(
  SELECT custid, val,
    ROW_NUMBER() OVER( PARTITION BY custid
                       ORDER BY orderdate, orderid ) AS rownumasc,
    ROW_NUMBER() OVER( PARTITION BY custid
                       ORDER BY orderdate DESC, orderid DESC ) AS rownumdesc
  FROM Sales.OrderValues
),
C2 AS
(
  SELECT custid, AVG(val) AS avgval
  FROM C1
  WHERE 1 NOT IN (rownumasc, rownumdesc)
  GROUP BY custid
)
SELECT O.orderid, O.custid, O.orderdate, O.val,
  O.val - C2.avgval AS diff
FROM Sales.OrderValues AS O
  LEFT OUTER JOIN C2
    ON O.custid = C2.custid;

-- Nested value_of expression at row function

-- cur value minus average without cur order date for customer

-- In standard (not supported in T-SQL)
SELECT orderid, custid, orderdate, val,
  val - AVG( CASE
              WHEN orderdate <> VALUE OF orderdate AT CURRENT_ROW
                THEN val
             END )
          OVER( PARTITION BY custid ) AS diff
FROM Sales.OrderValues;

-- Moving average of last 14 days with RANGE
SELECT orderid, custid, orderdate, val,
  AVG(val) OVER( PARTITION BY custid
                 ORDER BY orderdate
                 RANGE BETWEEN INTERVAL '13' DAY PRECEDING
                           AND CURRENT ROW ) AS movingavg14days
FROM Sales.OrderValues;

-- Emulating RANGE with nested window functions
SELECT orderid, custid, orderdate, val,
  AVG( CASE WHEN DATEDIFF(day, orderdate, VALUE OF orderdate AT CURRENT_ROW)
                  BETWEEN 0 AND 13
              THEN val END )
    OVER( PARTITION BY custid
          ORDER BY orderdate
          RANGE UNBOUNDED PRECEDING ) AS movingavg14days
FROM Sales.OrderValues;

---------------------------------------------------------------------
-- NULL treatment clause (IGNORE NULLS | RESPECT NULLS)
---------------------------------------------------------------------

-- Sample data
SET NOCOUNT ON;
USE TSQLV5;

DROP TABLE IF EXISTS dbo.T1;
GO

CREATE TABLE dbo.T1
(
  id INT NOT NULL CONSTRAINT PK_T1 PRIMARY KEY,
  col1 INT NULL
);

INSERT INTO dbo.T1(id, col1) VALUES
  ( 2, NULL),
  ( 3,   10),
  ( 5,   -1),
  ( 7, NULL),
  (11, NULL),
  (13,  -12),
  (17, NULL),
  (19, NULL),
  (23, 1759);

-- In standard (not supported in T-SQL)
SELECT id, col1,
  COALESCE(col1, LAG(col1) IGNORE NULLS OVER(ORDER BY id)) AS lastval
FROM dbo.T1;

-- Workaround in T-SQL
WITH C AS
(
  SELECT id, col1,
    MAX(CASE WHEN col1 IS NOT NULL THEN id END)
      OVER(ORDER BY id
           ROWS UNBOUNDED PRECEDING) AS grp
  FROM dbo.T1
)
SELECT id, col1,
  MAX(col1) OVER(PARTITION BY grp
                 ORDER BY id
                 ROWS UNBOUNDED PRECEDING)
FROM C;

---------------------------------------------------------------------
-- OFFSET-FETCH
---------------------------------------------------------------------

-- Simple example
USE TSQLV5;

SELECT orderid, orderdate, custid, empid
FROM Sales.Orders
ORDER BY orderdate DESC, orderid DESC
OFFSET 50 ROWS FETCH NEXT 25 ROWS ONLY;

-- Optimization
USE PerformanceV5;

-- Stats ON
SET STATISTICS IO ON;

-- Get page 10 with page size 25, 777 reads
DECLARE @pagenum AS BIGINT = 10, @pagesize AS BIGINT = 25;

SELECT orderid, orderdate, custid, empid
FROM dbo.Orders
ORDER BY orderid
OFFSET (@pagenum - 1) * @pagesize ROWS FETCH NEXT @pagesize ROWS ONLY;
GO

-- Optimized solution, 171 reads
DECLARE @pagenum AS BIGINT = 10, @pagesize AS BIGINT = 25;

WITH Keys AS
(
  SELECT orderid
  FROM dbo.Orders
  ORDER BY orderid
  OFFSET (@pagenum - 1) * @pagesize ROWS FETCH NEXT @pagesize ROWS ONLY
)
SELECT O.orderid, O.orderdate, O.custid, O.empid
FROM dbo.Orders AS O
  INNER JOIN Keys AS K
    ON O.orderid = K.orderid;

-- Stats OFF
SET STATISTICS IO, TIME OFF;

-- Median example
-- Run the following code to create and populate
-- the Employees and Orders tables in tempdb:
SET NOCOUNT ON;
USE tempdb;
IF OBJECT_ID('dbo.Orders') IS NOT NULL DROP TABLE dbo.Orders;
IF OBJECT_ID('dbo.Employees') IS NOT NULL DROP TABLE dbo.Employees;
GO

CREATE TABLE dbo.Employees
(
  empid   INT         NOT NULL,
  empname VARCHAR(20) NOT NULL
  CONSTRAINT PK_Employees PRIMARY KEY(empid)
);
GO

INSERT INTO dbo.Employees(empid, empname)
  VALUES(1, 'emp 1'),(2, 'emp 2'), (3, 'emp 3'), (4, 'emp 4');

CREATE TABLE dbo.Orders
(
  orderid   int        NOT NULL,
  orderdate datetime   NOT NULL,
  empid     int        NOT NULL,
  custid    varchar(5) NOT NULL,
  qty       int        NOT NULL,
  CONSTRAINT PK_Orders PRIMARY KEY NONCLUSTERED(orderid),
  CONSTRAINT FK_Orders_Employees
    FOREIGN KEY(empid) REFERENCES dbo.Employees(empid)
);
GO

INSERT INTO dbo.Orders(orderid, orderdate, empid, custid, qty)
  VALUES(30001, '20180802', 3, 'A', 10),
        (10001, '20181224', 1, 'A', 10),
        (10005, '20181224', 1, 'B', 30),
        (40001, '20190109', 4, 'A', 40),
        (10006, '20190118', 1, 'C', 10),
        (20001, '20190212', 2, 'B', 20),
        (40005, '20200212', 4, 'A', 10),
        (20002, '20200216', 2, 'C', 20),
        (30003, '20200418', 3, 'B', 15),
        (30004, '20180418', 3, 'C', 20),
        (30007, '20120907', 3, 'D', 30);

-- Return the median quantity for each employee.
-- Median is the middle value if there's an odd number of elements
-- and the average of the two middle values if there's an even number
-- of elements.
-- Assume high density of the empid column.

-- Desired result:
empid       median
----------- ---------------------------------------
1           10.000000
2           20.000000
3           17.500000
4           25.000000

-- Solution
USE tempdb;

CREATE INDEX idx_empid_qty ON dbo.Orders(empid, qty);

-- Solution using APPLY and OFFSET-FETCH (highly efficient)
WITH C AS
(
  SELECT
    empid,
    COUNT(*) AS cnt,
    (COUNT(*) - 1) / 2 AS ov,
    2 - COUNT(*) % 2 AS fv
  FROM dbo.Orders
  GROUP BY empid
)
SELECT C.empid, AVG(1. * A.qty) AS median
FROM C CROSS APPLY ( SELECT O.qty
                     FROM dbo.Orders AS O
                     WHERE O.empid = C.empid
                     ORDER BY O.qty
                     OFFSET C.ov ROWS FETCH NEXT C.fv ROWS ONLY ) AS A
GROUP BY C.empid;
