## Methodology

We apply Chain of Thought (CoT) combined with Few-shot technique in our prompt.

### CoT Workflow

There are four steps in our CoT process:

1. Function Identification: identify functions containing token swapping or liquidity-related operation.
2. Parameter Identification: identify slippage paramters in those functions.
3. Paremeter Examination: check if there exist possible vulnerability patterns in the slippage parameters.
4. Result Review: review the vulnerability found in step 3 to check if the vulnerability found does exist.

```
[Function Identification]
    - contains certain operations -> [Parameter Identification]
    --> [Paremeter Examination]
    --> [Result Review]
```

### Few-shot

There are five examples included in our prompt:

1. A positive example (contains slippage-related vulnerability) for slippage parameter set to 0.
2. A positive example for slippage parameter unused.
3. A positive example for slipppage parameter hardcoded.
4. A negative example (contains no slippage-related vulnerability) for a safe implementation of slippage parameter.
5. A negative example for vulnerability detected but revised to no vulnerability in step 4.

## Result

* Model Applied: GPT-4o-mini
* Positive Test Cases: 84
* Negative Test Cases: 29

|  TP  |  FP  |  TN  |  FN  | Accuracy | Precision | Recall | F1 |
| ---- | ---- | ---- | ---- | -------- | --------- | ------ | -- |
|      |      |      |      |          |           |        |    |