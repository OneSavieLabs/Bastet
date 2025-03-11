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

|  TP  |  TN  |  FN  |  FP  |  FP_t  | Accuracy | Precision | Recall |   F1   |
| ---- | ---- | ---- | ---- | ------ | -------- | --------- | ------ | ------ |
|  74  |  19  |  3   |  10  |    7   |   0.82   |   0.81    |  0.88  |  0.84  |

* $` TP `$ (True Positive): The LLM correctly identifies the vulnerability with the correct type.
* $` TN `$ (True Negative): The LLM correctly concludes that the code is not vulnerable.
* $` FN `$ (False Negative): The LLM incorrectly identifies a vulnerable code segment as non-vulnerable.
* $` FP `$ (False Positive): The LLM incorrectly identifies a non-vulnerable code segment as vulnerable.
* $` FP_t `$ (False Positive Type): The LLM identifies a vulnerable code segment as vulnerable, but with an incorrect vulnerability type.

Since FP-type includes both false positives (reporting a non- existent vulnerability) and false negatives (failing to report an ex- isting vulnerability), we calculate the precision and recall of the LLMs’ vulnerability detection results as follows:

* $` Precision = \frac {TP}{TP + FP + FP_t} `$
* $` Recall = \frac {TP}{TP + FN + FP_t} `$ 

## References

1. The definitions for confusion matrix, precision, and recall refer to [LLM4Vuln: A Unified Evaluation Framework for Decoupling and Enhancing LLMs’ Vulnerability Reasoning](https://arxiv.org/pdf/2401.16185).
