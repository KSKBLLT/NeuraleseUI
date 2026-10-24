"""Optional offline research tooling; Torch is never an app dependency."""
import pytest

torch = pytest.importorskip("torch")
from tools.language_models.compression_study import fit_down_projection, grade


def test_numeric_grader_does_not_accept_substrings_or_intermediate_answers():
    row = {"numeric_answer": 14}
    assert grade(row, "Answer: 14")
    assert not grade(row, "Answer: 114")
    assert not grade(row, "Intermediate: 14.\nAnswer: 15")


def test_biasless_ridge_recovers_removed_correlated_channels():
    torch.manual_seed(42)
    selected = torch.randn(100, 4)
    z = torch.cat([selected, selected @ torch.randn(4, 4)], 1)
    weight = torch.randn(3, 8)
    keep = torch.arange(4)
    fitted, bias = fit_down_projection(z, weight, keep, "ridge_no_bias")
    assert bias is None
    target = z @ weight.T
    plain_error = (selected @ weight[:, keep].T - target).square().mean()
    fitted_error = (selected @ fitted.T - target).square().mean()
    assert fitted_error < plain_error * .001
